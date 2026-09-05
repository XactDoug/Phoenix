--[[
* dbox - Ashita v4 addon for the FFXI delivery box.
*
* Retrieves items from either delivery box (incoming or outgoing) by slot, from a chat command,
* without clicking through the delivery box window.
*
* Everything here is driven by the client to server packet GP_CLI_COMMAND_PBX (0x04D) and the
* server to client reply GP_SERV_COMMAND_PBX_RESULT (0x04B). Field names match the PS2 names
* used by both XiPackets and the Phoenix/LandSandBoat server source, so behaviour can be checked
* against src/map/packets/c2s/0x04d_pbx.cpp and src/map/utils/dboxutils.cpp.
*
*   https://github.com/atom0s/XiPackets/tree/main/world/client/0x004D
*   https://github.com/atom0s/XiPackets/tree/main/world/server/0x004B
*
* Commands:
*
*   /dbox get <slot> [in|out]   Take the item in <slot> of the given box. Box defaults to in.
*   /dbox <slot> [in|out]       Shorthand for the above.
*   /dbox all [in|out]          Take every item currently held in the 8 cells of the given box.
*   /dbox list [in|out]         Print the contents of the given box.
*   /dbox new                   Pull waiting deliveries into the free cells of the incoming box.
*   /dbox close                 Send PostClose, closing the box server side.
*   /dbox mode [queue|inject]   Show or change how packets are sent.
*   /dbox help                  Print the command list.
*
* Read the README next to this file before using it. In short: stand at a delivery NPC with the
* delivery box window open, then use the commands.
--]]

addon.name    = 'dbox';
addon.author  = 'Phoenix';
addon.version = '1.0';
addon.desc    = 'Retrieve items from the incoming and outgoing delivery boxes by slot.';

require 'common';

local chat = require 'chat';
local ffi  = require 'ffi';

local fmt = string.format;

--[[
* Configuration. Edit these, or use /dbox mode at runtime for send_mode.
--]]
local config = T{
    -- Slot numbering used by the commands.
    --   1 -> /dbox get 1 means the first cell, which is PostWorkNo 0 on the wire (matches the game window).
    --   0 -> /dbox get 0 means PostWorkNo 0 (matches server logs and dboxutils.cpp).
    slot_base = 1,

    -- How outgoing packets are sent.
    --   'queue'  -> the game's own packet queue, so the client stamps a valid packet sync value.
    --   'inject' -> raw injection through Ashita.
    -- LandSandBoat drops any sub packet whose sync is not greater than the session's last one
    -- (see src/map/map_networking.cpp), so 'queue' is the safer default.
    send_mode = 'queue',

    -- Seconds to wait for a 0x04B reply before giving up on a step.
    reply_timeout = 3.0,

    -- Seconds to pause between packets while working through multiple slots.
    step_delay = 0.15,
};

-- Packet ids.
local PBX_C2S = 0x04D;
local PBX_S2C = 0x04B;

-- GP_CLI_COMMAND_PBX_COMMAND
local COMMAND = T{
    Work      = 0x01,
    Set       = 0x02,
    Send      = 0x03,
    Cancel    = 0x04,
    Check     = 0x05,
    Recv      = 0x06,
    Confirm   = 0x07,
    Accept    = 0x08,
    Reject    = 0x09,
    Get       = 0x0A,
    Clear     = 0x0B,
    Query     = 0x0C,
    DeliOpen  = 0x0D,
    PostOpen  = 0x0E,
    PostClose = 0x0F,
};

-- GP_CLI_COMMAND_PBX_BOXNO
local BOXNO = T{
    None     = -1,
    Incoming = 1,
    Outgoing = 2,
};

-- Number of cells the client and server keep open per box.
local CELL_COUNT = 8;

-- Gil arrives in the delivery box as this item id and does not need a free inventory slot.
local GIL_ITEM_ID = 65535;

--[[
* Runtime state. state.log holds the 0x04B replies seen since the current operation started.
--]]
local state = T{
    busy = false,
    open = nil,  -- Box the server currently has open for us, tracked from replies.
    log  = T{},
};

--[[
* Helpers.
--]]

local function box_name(box)
    if (box == BOXNO.Incoming) then
        return 'incoming';
    elseif (box == BOXNO.Outgoing) then
        return 'outgoing';
    end
    return 'none';
end

local function msg(text)
    print(chat.header('dbox'):append(chat.message(text)));
end

local function err(text)
    print(chat.header('dbox'):append(chat.error(text)));
end

local function ok(text)
    print(chat.header('dbox'):append(chat.success(text)));
end

-- Converts a signed value to its single byte representation.
local function to_byte(value)
    return math.floor(value or 0) % 0x100;
end

local function write_i32(packet, offset, value)
    value = math.floor(value or 0) % 0x100000000;
    packet[offset + 1] = value % 0x100;
    packet[offset + 2] = math.floor(value / 0x100) % 0x100;
    packet[offset + 3] = math.floor(value / 0x10000) % 0x100;
    packet[offset + 4] = math.floor(value / 0x1000000) % 0x100;
end

local function read_u8(data, offset)
    return data:byte(offset + 1) or 0;
end

local function read_i8(data, offset)
    local value = read_u8(data, offset);
    if (value > 0x7F) then
        return value - 0x100;
    end
    return value;
end

local function read_u16(data, offset)
    return read_u8(data, offset) + (read_u8(data, offset + 1) * 0x100);
end

local function read_u32(data, offset)
    return read_u16(data, offset) + (read_u16(data, offset + 2) * 0x10000);
end

local function read_string(data, offset, length)
    local text = data:sub(offset + 1, offset + length);
    local stop = text:find('\0', 1, true);
    if (stop ~= nil) then
        text = text:sub(1, stop - 1);
    end
    return text;
end

-- Item name for display; the resource name arrays are language indexed.
local function item_name(itemId)
    if (itemId == nil or itemId == 0) then
        return 'empty';
    end
    if (itemId == GIL_ITEM_ID) then
        return 'gil';
    end

    local resource = AshitaCore:GetResourceManager():GetItemById(itemId);
    if (resource ~= nil) then
        for _, index in ipairs(T{ 3, 2, 1 }) do
            local success, name = pcall(function ()
                return resource.Name[index];
            end);
            if (success and type(name) == 'string' and #name > 0) then
                return name;
            end
        end
    end

    return fmt('item %u', itemId);
end

-- Free slots in the main inventory. Index 0 of container 0 is gil, real items start at 1.
local function inventory_free()
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    local max       = inventory:GetContainerCountMax(0);
    local used      = 0;

    for index = 1, max do
        local item = inventory:GetContainerItem(0, index);
        if (item ~= nil and item.Id ~= 0 and item.Count > 0) then
            used = used + 1;
        end
    end

    return max - used;
end

-- Turns a command line slot number into a wire PostWorkNo.
local function to_post_work_no(argument)
    local value = tonumber(argument);
    if (value == nil) then
        return nil;
    end

    local postWorkNo = math.floor(value) - config.slot_base;
    if (postWorkNo < 0 or postWorkNo >= CELL_COUNT) then
        return nil;
    end

    return postWorkNo;
end

-- Turns a wire PostWorkNo back into the number the user types.
local function to_slot_label(postWorkNo)
    return postWorkNo + config.slot_base;
end

local function to_box(argument)
    if (argument == nil) then
        return BOXNO.Incoming;
    end

    local value = argument:lower();
    if (value:any('in', 'inc', 'incoming', 'recv', '1')) then
        return BOXNO.Incoming;
    end
    if (value:any('out', 'outgoing', 'send', 'deli', '2')) then
        return BOXNO.Outgoing;
    end

    return nil;
end

-- Result codes the server sends back in the Result field.
local function result_text(result)
    if (result == 0x01) then
        return 'ok';
    elseif (result == 0xB9) then
        return 'inventory is full';
    elseif (result == 0xBA) then
        return 'the server could not complete the request';
    elseif (result == 0xEB) then
        return 'the server could not deliver the next item';
    end
    return fmt('error code %d', result);
end

--[[
* Packet building and sending.
--]]

-- Builds a full 0x20 byte GP_CLI_COMMAND_PBX packet as a byte table.
local function build_pbx(command, boxNo, postWorkNo, itemWorkNo, itemStacks)
    local packet = T{};
    for index = 1, 0x20 do
        packet[index] = 0;
    end

    -- Header. Byte 0 is the low 8 bits of the id, byte 1 is (id >> 8) | (size in dwords << 1).
    -- 0x04D is 0x20 bytes, so 8 dwords: (0x04D >> 8) | (8 << 1) = 0x10.
    packet[0x01] = 0x4D;
    packet[0x02] = 0x10;

    packet[0x05] = to_byte(command);     -- 0x04 Command
    packet[0x06] = to_byte(boxNo);       -- 0x05 BoxNo
    packet[0x07] = to_byte(postWorkNo);  -- 0x06 PostWorkNo
    packet[0x08] = to_byte(itemWorkNo);  -- 0x07 ItemWorkNo

    write_i32(packet, 0x08, itemStacks); -- 0x08 ItemStacks

    -- 0x0C Result and 0x0D to 0x0F ResParam1 to ResParam3 must be zero or the server rejects the packet.
    -- 0x10 to 0x1F TargetName stays zeroed; only Set and Query use it.

    return packet;
end

local function send_pbx(command, boxNo, postWorkNo, itemWorkNo, itemStacks)
    local packet = build_pbx(command, boxNo, postWorkNo, itemWorkNo, itemStacks);

    if (config.send_mode == 'inject') then
        AshitaCore:GetPacketManager():AddOutgoingPacket(PBX_C2S, packet);
        return;
    end

    -- The game's own queue writes the header, including a valid sync value.
    AshitaCore:GetPacketManager():QueuePacket(PBX_C2S, 0x20, 0, 0, 0, function (ptr)
        local raw = ffi.cast('uint8_t*', ptr);
        for offset = 0x04, 0x1F do
            raw[offset] = packet[offset + 1];
        end
    end);
end

--[[
* Reply handling.
--]]

ashita.events.register('packet_in', 'dbox_packet_in', function (e)
    if (e.id ~= PBX_S2C) then
        return;
    end

    local reply = T{
        command = read_u8(e.data, 0x04),
        box     = read_i8(e.data, 0x05),
        slot    = read_i8(e.data, 0x06),
        result  = read_u8(e.data, 0x0C),
        param1  = read_u8(e.data, 0x0D),
        param2  = read_u8(e.data, 0x0E),
        param3  = read_u8(e.data, 0x0F),
        itemid  = 0,
        stack   = 0,
        person  = '',
    };

    -- The long form of the reply (0x58 bytes) carries the cell contents.
    if (e.size >= 0x58) then
        reply.person = read_string(e.data, 0x14, 16);
        reply.itemid = read_u16(e.data, 0x30);
        reply.stack  = read_u32(e.data, 0x38);
    end

    -- Track which box the server has open for us, including boxes opened by the game itself.
    if (reply.command == COMMAND.PostOpen and reply.result == 0x01) then
        state.open = BOXNO.Incoming;
    elseif (reply.command == COMMAND.DeliOpen and reply.result == 0x01) then
        state.open = BOXNO.Outgoing;
    elseif (reply.command == COMMAND.PostClose) then
        state.open = nil;
    end

    if (state.busy) then
        state.log[#state.log + 1] = reply;
    end
end);

local function log_mark()
    return #state.log;
end

-- Waits for a reply logged after mark that matches command, and box when given.
local function wait_reply(mark, command, box, timeout)
    local deadline = os.clock() + (timeout or config.reply_timeout);

    while (os.clock() < deadline) do
        for index = mark + 1, #state.log do
            local reply = state.log[index];
            if (reply.command == command and (box == nil or reply.box == box)) then
                return reply, index;
            end
        end
        coroutine.sleepf(1);
    end

    return nil, mark;
end

--[[
* Box operations.
--]]

-- Puts the server into the requested box mode. Skipped when it is already there.
local function open_box(box)
    if (state.open == box) then
        return true;
    end

    local command = (box == BOXNO.Incoming) and COMMAND.PostOpen or COMMAND.DeliOpen;
    local mark    = log_mark();

    send_pbx(command, BOXNO.None, -1, -1, -1);

    local reply = wait_reply(mark, command);
    if (reply == nil) then
        err(fmt('No reply when opening the %s box. Is the delivery box window open?', box_name(box)));
        return false;
    end
    if (reply.result ~= 0x01) then
        err(fmt('The server refused to open the %s box (%s).', box_name(box), result_text(reply.result)));
        return false;
    end

    return true;
end

-- Sends Work and collects the 8 cell replies. Returns a table keyed by PostWorkNo.
local function read_cells(box)
    local mark = log_mark();

    send_pbx(COMMAND.Work, box, -1, -1, -1);

    local cells    = T{};
    local deadline = os.clock() + config.reply_timeout;
    local seen     = 0;
    local index    = mark;

    while (os.clock() < deadline and seen < CELL_COUNT) do
        while (index < #state.log) do
            index = index + 1;
            local reply = state.log[index];
            if (reply.command == COMMAND.Work and reply.box == box and reply.slot >= 0 and reply.slot < CELL_COUNT) then
                if (cells[reply.slot] == nil) then
                    seen = seen + 1;
                end
                cells[reply.slot] = reply;
            end
        end
        if (seen < CELL_COUNT) then
            coroutine.sleepf(1);
        end
    end

    if (seen == 0) then
        err(fmt('No reply when reading the %s box.', box_name(box)));
        return nil;
    end

    return cells;
end

-- Asks the server how many deliveries are waiting behind the 8 cells.
local function waiting_count(box)
    local mark = log_mark();

    send_pbx(COMMAND.Check, box, -1, -1, -1);

    local deadline = os.clock() + config.reply_timeout;
    local index    = mark;

    while (os.clock() < deadline) do
        while (index < #state.log) do
            index = index + 1;
            local reply = state.log[index];
            if (reply.command == COMMAND.Check and reply.box == box and reply.result == 0x01) then
                return (box == BOXNO.Incoming) and reply.param2 or reply.param3;
            end
        end
        coroutine.sleepf(1);
    end

    return nil;
end

-- Takes the item in one cell. Returns true when the item reached the inventory.
local function take_cell(box, postWorkNo, cell)
    local mark = log_mark();

    send_pbx(COMMAND.Get, box, postWorkNo, -1, -1);

    local reply = wait_reply(mark, COMMAND.Get, box);
    if (reply == nil) then
        err(fmt('No reply taking slot %d. The cell may already be empty.', to_slot_label(postWorkNo)));
        return false;
    end
    if (reply.result ~= 0x01) then
        err(fmt('Could not take slot %d: %s.', to_slot_label(postWorkNo), result_text(reply.result)));
        return false;
    end

    ok(fmt('Slot %d: %s x%d', to_slot_label(postWorkNo), item_name(cell.itemid), cell.stack));
    return true;
end

--[[
* Commands.
--]]

local function print_help()
    msg('Commands:');
    msg('  /dbox get <slot> [in|out]  Take the item in a slot. Box defaults to in.');
    msg('  /dbox <slot> [in|out]      Same thing, shorter.');
    msg('  /dbox all [in|out]         Take everything currently in the 8 cells.');
    msg('  /dbox list [in|out]        Print the contents of a box.');
    msg('  /dbox new                  Pull waiting deliveries into free incoming cells.');
    msg('  /dbox close                Close the box server side.');
    msg('  /dbox mode [queue|inject]  Show or change how packets are sent.');
    msg(fmt('Slots are numbered from %d. Stand at a delivery NPC with the box window open.', config.slot_base));
end

local function command_list(box)
    if (not open_box(box)) then
        return;
    end

    local cells = read_cells(box);
    if (cells == nil) then
        return;
    end

    msg(fmt('%s box:', (box_name(box):gsub('^%l', string.upper))));

    local empty = true;
    for postWorkNo = 0, CELL_COUNT - 1 do
        local cell = cells[postWorkNo];
        if (cell ~= nil and cell.itemid ~= 0) then
            empty = false;
            local who = (#cell.person > 0) and fmt(' (%s)', cell.person) or '';
            msg(fmt('  %d: %s x%d%s', to_slot_label(postWorkNo), item_name(cell.itemid), cell.stack, who));
        end
    end

    if (empty) then
        msg('  (no items)');
    end

    local waiting = waiting_count(box);
    if (waiting ~= nil and waiting > 0) then
        if (box == BOXNO.Incoming) then
            msg(fmt('  %d more waiting behind the cells.', waiting));
        else
            -- For the outgoing box the server counts items the receiver has already taken.
            msg(fmt('  %d sent item(s) have been picked up.', waiting));
        end
    end
end

local function command_get(box, postWorkNo)
    if (not open_box(box)) then
        return;
    end

    local cells = read_cells(box);
    if (cells == nil) then
        return;
    end

    local cell = cells[postWorkNo];
    if (cell == nil or cell.itemid == 0) then
        err(fmt('Slot %d of the %s box is empty.', to_slot_label(postWorkNo), box_name(box)));
        return;
    end

    if (cell.itemid ~= GIL_ITEM_ID and inventory_free() < 1) then
        err('Your inventory is full.');
        return;
    end

    take_cell(box, postWorkNo, cell);
end

local function command_all(box)
    if (not open_box(box)) then
        return;
    end

    local cells = read_cells(box);
    if (cells == nil) then
        return;
    end

    local free  = inventory_free();
    local taken = 0;
    local left  = 0;

    for postWorkNo = 0, CELL_COUNT - 1 do
        local cell = cells[postWorkNo];
        if (cell ~= nil and cell.itemid ~= 0) then
            if (cell.itemid ~= GIL_ITEM_ID and free < 1) then
                left = left + 1;
            else
                if (take_cell(box, postWorkNo, cell)) then
                    taken = taken + 1;
                    if (cell.itemid ~= GIL_ITEM_ID) then
                        free = free - 1;
                    end
                else
                    left = left + 1;
                end
                coroutine.sleep(config.step_delay);
            end
        end
    end

    msg(fmt('Took %d item(s) from the %s box.', taken, box_name(box)));

    if (left > 0) then
        err(fmt('%d item(s) left in the cells. Inventory space is the usual reason.', left));
    end

    if (box == BOXNO.Incoming) then
        local waiting = waiting_count(box);
        if (waiting ~= nil and waiting > 0) then
            msg(fmt('%d more waiting behind the cells. Use /dbox new, then /dbox all again.', waiting));
        end
    end
end

local function command_new()
    local box = BOXNO.Incoming;

    if (not open_box(box)) then
        return;
    end

    local cells = read_cells(box);
    if (cells == nil) then
        return;
    end

    local waiting = waiting_count(box);
    if (waiting == nil) then
        err('The server did not report how many deliveries are waiting.');
        return;
    end
    if (waiting < 1) then
        msg('Nothing is waiting behind the cells.');
        return;
    end

    local pulled = 0;

    for postWorkNo = 0, CELL_COUNT - 1 do
        if (pulled >= waiting) then
            break;
        end

        local cell = cells[postWorkNo];
        if (cell == nil or cell.itemid == 0) then
            local mark = log_mark();

            -- Recv moves one waiting delivery into the empty cell named by PostWorkNo.
            -- The client sends ItemWorkNo as 1 here and the server validates that.
            send_pbx(COMMAND.Recv, box, postWorkNo, 1, -1);

            local reply = wait_reply(mark, COMMAND.Recv, box);
            if (reply == nil) then
                err(fmt('No reply pulling a delivery into slot %d.', to_slot_label(postWorkNo)));
                break;
            end
            if (reply.result ~= 0x01 and reply.result ~= 0x02) then
                err(fmt('Could not pull a delivery into slot %d: %s.', to_slot_label(postWorkNo), result_text(reply.result)));
                break;
            end

            pulled = pulled + 1;
            coroutine.sleep(config.step_delay);
        end
    end

    msg(fmt('Pulled %d delivery(s) into the incoming cells.', pulled));
end

local function command_close()
    send_pbx(COMMAND.PostClose, BOXNO.None, -1, -1, -1);
    state.open = nil;
    msg('Sent PostClose.');
end

--[[
* Runs an operation with the reply log cleared and the addon marked busy.
--]]
local function run(handler)
    if (state.busy) then
        err('Still working on the last command.');
        return;
    end

    state.busy = true;
    state.log  = T{};

    local success, message = pcall(handler);

    state.busy = false;
    state.log  = T{};

    if (not success) then
        err(fmt('Failed: %s', message));
    end
end

ashita.events.register('command', 'dbox_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:lower():any('/dbox')) then
        return;
    end

    e.blocked = true;

    if (#args == 1 or args[2]:any('help', '?')) then
        print_help();
        return;
    end

    local action = args[2]:lower();

    -- /dbox mode [queue|inject]
    if (action == 'mode') then
        if (#args > 2) then
            local mode = args[3]:lower();
            if (not mode:any('queue', 'inject')) then
                err('Mode must be queue or inject.');
                return;
            end
            config.send_mode = mode;
        end
        msg(fmt('Send mode: %s', config.send_mode));
        return;
    end

    if (action == 'close') then
        run(command_close);
        return;
    end

    if (action == 'new') then
        run(command_new);
        return;
    end

    if (action:any('list', 'ls')) then
        local box = to_box(args[3]);
        if (box == nil) then
            err('Box must be in or out.');
            return;
        end
        run(function ()
            command_list(box);
        end);
        return;
    end

    if (action == 'all') then
        local box = to_box(args[3]);
        if (box == nil) then
            err('Box must be in or out.');
            return;
        end
        run(function ()
            command_all(box);
        end);
        return;
    end

    -- /dbox get <slot> [box] and the /dbox <slot> [box] shorthand.
    local slotArg, boxArg;
    if (action == 'get') then
        slotArg = args[3];
        boxArg  = args[4];
    else
        slotArg = args[2];
        boxArg  = args[3];
    end

    local postWorkNo = to_post_work_no(slotArg);
    if (postWorkNo == nil) then
        err(fmt('Slot must be a number from %d to %d.', config.slot_base, config.slot_base + CELL_COUNT - 1));
        return;
    end

    local box = to_box(boxArg);
    if (box == nil) then
        err('Box must be in or out.');
        return;
    end

    run(function ()
        command_get(box, postWorkNo);
    end);
end);
