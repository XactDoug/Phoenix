-- Test harness: stubs the Ashita v4 API and simulates the Phoenix delivery box server.

------------------------------------------------------------------ Ashita stubs
addon = {};

local function tmeta(t)
    return setmetatable(t or {}, { __index = {
        any = function (self, fn)
            for _, v in pairs(self) do
                if (type(fn) == 'function' and fn(v)) then return true; end
            end
            return false;
        end,
    }});
end
T = tmeta;

-- string extensions used by the addon / chat lib
function string.any(self, ...)
    for _, v in ipairs({ ... }) do
        if (self == v) then return true; end
    end
    return false;
end
function string.append(self, other) return self .. other; end
function string.args(self)
    local out = {};
    for word in self:gmatch('%S+') do out[#out + 1] = word; end
    return T(out);
end

local handlers = {};
ashita = { events = { register = function (name, alias, fn) handlers[name] = fn; end } };

package.preload['common'] = function () return {}; end
package.preload['chat'] = function ()
    return {
        header  = function (s) return '[' .. s .. '] '; end,
        message = function (s) return s; end,
        error   = function (s) return 'ERR: ' .. s; end,
        success = function (s) return 'OK: ' .. s; end,
    };
end
package.preload['ffi'] = function ()
    return { cast = function (_, ptr) return ptr; end };
end

-- Virtual clock: one yield is one frame at 60fps, so timeouts are deterministic.
local vclock = 0;
os.clock = function () return vclock; end
coroutine.sleep  = function (seconds) vclock = vclock + (seconds or 0); coroutine.yield(); end
coroutine.sleepf = function (frames) vclock = vclock + ((frames or 1) / 60); coroutine.yield(); end

------------------------------------------------------------------ fake server
local server = {
    opened    = nil,
    container = {},           -- cells the server currently has loaded (slot -> item)
    boxes     = {
        [1] = { cells = {}, queue = {} },  -- incoming
        [2] = { cells = {} },              -- outgoing
    },
    replies   = {},           -- pending 0x04B packets for the client
    sent      = {},           -- log of packets the addon sent
};

local function put(str, offset, value, width)
    -- little endian write into a byte array table
    for i = 0, width - 1 do
        str[offset + i] = math.floor(value / (256 ^ i)) % 256;
    end
end

local function reply(command, boxno, slot, result, param1, param2, param3, item, person)
    local size  = item and 0x58 or 0x14;
    local bytes = {};
    for i = 0, size - 1 do bytes[i] = 0; end

    bytes[0] = 0x4B;
    bytes[1] = size / 2;
    put(bytes, 0x04, command % 256, 1);
    put(bytes, 0x05, boxno % 256, 1);
    put(bytes, 0x06, slot % 256, 1);
    put(bytes, 0x07, 0xFF, 1);              -- ItemWorkNo -1
    put(bytes, 0x08, 0xFFFFFFFF, 4);        -- ItemStacks -1
    put(bytes, 0x0C, result % 256, 1);
    put(bytes, 0x0D, (param1 or 0xFF) % 256, 1);
    put(bytes, 0x0E, (param2 or 0xFF) % 256, 1);
    put(bytes, 0x0F, (param3 or 0xFF) % 256, 1);

    if (item) then
        local name = person or '';
        for i = 1, #name do put(bytes, 0x14 + i - 1, name:byte(i), 1); end
        put(bytes, 0x30, item.itemid, 2);
        put(bytes, 0x38, item.stack, 4);
    end

    local out = {};
    for i = 0, size - 1 do out[#out + 1] = string.char(bytes[i]); end
    server.replies[#server.replies + 1] = { id = 0x04B, size = size, data = table.concat(out) };
end

local handlers_ref;  -- set after the addon registers its callbacks

-- Mirrors the packet back through the addon's packet_out callback, as Ashita would.
local function echo_packet_out(id, packet)
    if (handlers_ref == nil or handlers_ref['packet_out'] == nil) then return; end
    local chars = {};
    for i = 1, 0x20 do chars[#chars + 1] = string.char(packet[i] or 0); end
    handlers_ref['packet_out']({ id = id, size = 0x20, data = table.concat(chars), injected = true });
end

local function handle(id, packet)
    echo_packet_out(id, packet);
    -- packet is a 1-based byte table of the full 0x20 byte packet
    local command    = packet[0x05];
    local boxno      = packet[0x06] > 127 and packet[0x06] - 256 or packet[0x06];
    local postWorkNo = packet[0x07] > 127 and packet[0x07] - 256 or packet[0x07];
    local itemWorkNo = packet[0x08] > 127 and packet[0x08] - 256 or packet[0x08];

    server.sent[#server.sent + 1] = { command = command, box = boxno, slot = postWorkNo, itemWorkNo = itemWorkNo };

    -- Validation mirroring 0x04d_pbx.cpp: Result and ResParams must be zero.
    for _, offset in ipairs({ 0x0D, 0x0E, 0x0F, 0x10 }) do
        assert(packet[offset] == 0, ('server rejected packet: byte %02X not zero'):format(offset - 1));
    end
    assert(packet[0x01] == 0x4D, 'bad packet id');
    assert(packet[0x02] == 0x10, ('bad size byte: %02X'):format(packet[0x02]));

    if (server.deaf) then return; end

    if (command == 0x0E) then           -- PostOpen
        assert(boxno == -1, 'PostOpen BoxNo must be None');
        server.opened = 1; server.container = {};
        reply(0x0E, 1, -1, 1);
    elseif (command == 0x0D) then       -- DeliOpen
        assert(boxno == -1, 'DeliOpen BoxNo must be None');
        server.opened = 2; server.container = {};
        reply(0x0D, 2, -1, 1);
    elseif (command == 0x0F) then       -- PostClose
        assert(boxno == -1, 'PostClose BoxNo must be None');
        server.opened = nil; server.container = {};
        reply(0x0F, -1, -1, 1);
    elseif (command == 0x01) then       -- Work
        if (server.opened == nil) then return; end  -- IsAnyDeliveryBoxOpen fails: logged and dropped
        assert(boxno == 1 or boxno == 2, 'Work BoxNo out of range');
        assert(itemWorkNo == -1, 'Work ItemWorkNo must be -1');
        server.container = {};
        local count = 0;
        for slot = 0, 7 do
            local item = server.boxes[boxno].cells[slot];
            if (item) then server.container[slot] = item; count = count + 1; end
        end
        for slot = 0, 7 do
            reply(0x01, boxno, slot, 1, count, nil, nil, server.container[slot], server.container[slot] and server.container[slot].person);
        end
    elseif (command == 0x05) then       -- Check
        assert(postWorkNo == -1, 'Check PostWorkNo must be -1');
        local waiting = (boxno == 1) and #server.boxes[1].queue or 0;
        reply(0x05, boxno, -1, 2, nil, (boxno == 1) and 0xFF or nil, (boxno == 2) and 0xFF or nil);
        reply(0x05, boxno, -1, 1, nil, (boxno == 1) and waiting or nil, (boxno == 2) and waiting or nil);
    elseif (command == 0x0A) then       -- Get
        if (server.opened == nil) then return; end  -- IsAnyDeliveryBoxOpen fails: logged and dropped
        assert(boxno == 1 or boxno == 2, 'Get BoxNo out of range');
        assert(postWorkNo >= 0 and postWorkNo <= 8, 'Get PostWorkNo out of range');
        local item = server.container[postWorkNo];
        if (item == nil) then return; end  -- server stays silent on an empty cell
        if (server.drop_next_get) then server.drop_next_get = false; return; end
        server.container[postWorkNo] = nil;
        server.boxes[boxno].cells[postWorkNo] = nil;
        reply(0x0A, boxno, postWorkNo, 1, 0, nil, nil, item);
    elseif (command == 0x06) then       -- Recv
        assert(boxno == 1, 'Recv BoxNo must be Incoming');
        assert(itemWorkNo == 1, 'Recv ItemWorkNo must be 1');
        if (server.opened ~= 1) then return; end    -- IsRecvBoxOpen fails: logged and dropped
        if (server.container[postWorkNo] ~= nil) then return; end
        local item = table.remove(server.boxes[1].queue, 1);
        if (item == nil) then return; end
        server.container[postWorkNo] = item;
        server.boxes[1].cells[postWorkNo] = item;
        reply(0x06, 1, postWorkNo, 2, 1);
        reply(0x06, 1, postWorkNo, 1, 1, nil, nil, item);
    else
        error(('unexpected command %02X'):format(command));
    end
end

------------------------------------------------------------------ core stubs
local inventory_used = 5;
local inventory_max  = 30;

AshitaCore = {
    GetPacketManager = function ()
        return {
            QueuePacket = function (_, id, size, a, b, c, cb)
                assert(size == 0x20, 'QueuePacket size');
                local buf = setmetatable({}, {
                    __index = function () return 0; end,
                    __newindex = function (t, k, v) rawset(t, k, v); end,
                });
                cb(buf);
                local packet = {};
                packet[0x01] = 0x4D; packet[0x02] = 0x10; packet[0x03] = 0; packet[0x04] = 0;
                for offset = 0x04, 0x1F do packet[offset + 1] = rawget(buf, offset) or 0; end
                handle(id, packet);
            end,
            AddOutgoingPacket = function (_, id, packet) handle(id, packet); end,
        };
    end,
    GetMemoryManager = function ()
        return {
            GetInventory = function ()
                return {
                    GetContainerCountMax = function () return inventory_max; end,
                    GetContainerItem = function (_, _, index)
                        if (index <= inventory_used) then return { Id = 100 + index, Count = 1 }; end
                        return { Id = 0, Count = 0 };
                    end,
                };
            end,
        };
    end,
    GetResourceManager = function ()
        return {
            GetItemById = function (_, id)
                return { Name = { [1] = 'JP', [2] = '', [3] = 'Item' .. id } };
            end,
        };
    end,
};

------------------------------------------------------------------ driver
local output = {};
local realprint = print;
print = function (...)
    local parts = {};
    for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v); end
    output[#output + 1] = table.concat(parts, ' ');
end

local here = (arg and arg[0] and arg[0]:match('^(.*)[/\\][^/\\]*$')) or '.';
dofile(here .. '/../dbox.lua');

handlers_ref = handlers;

local function pump()
    while (#server.replies > 0) do
        local e = table.remove(server.replies, 1);
        handlers['packet_in'](e);
    end
end

local function run_command(text)
    output = {};
    server.sent = {};
    local e = { command = text, blocked = false };
    local co = coroutine.create(function () handlers['command'](e); end);
    local guard = 0;
    while (coroutine.status(co) ~= 'dead') do
        local okk, msgg = coroutine.resume(co);
        if (not okk) then error(msgg); end
        pump();
        guard = guard + 1;
        if (guard > 20000) then error('command did not finish'); end
    end
    return output, e;
end

return {
    server = server,
    run = run_command,
    realprint = realprint,
    set_inventory = function (used, max) inventory_used = used; inventory_max = max; end,
};
