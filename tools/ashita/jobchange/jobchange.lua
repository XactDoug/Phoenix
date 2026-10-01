--[[
    jobchange - Ashita v4 addon
    Changes main job and/or sub job by sending the job change packet (0x100) directly.

    Usage:
        /jc WAR/NIN     change main to WAR, sub to NIN
        /jc WAR NIN     same as above
        /jc WAR         change main job only
        /jc /NIN        change sub job only
        /jc 1/13        job IDs work too

    The server only accepts this packet in your Mog House or in a zone with a
    Nomad Moogle (or similar), and only for jobs you have unlocked.

    Packet layout (client 0x100, 8 bytes):
        0x00  uint16  id (9 bits) + size in 4 byte words (7 bits)
        0x02  uint16  sync (filled by the client)
        0x04  uint8   main job index (0 = leave unchanged)
        0x05  uint8   sub job index  (0 = leave unchanged)
        0x06  uint16  padding
--]]

addon.name    = 'jobchange';
addon.author  = 'Xact Accounting';
addon.version = '1.0';
addon.desc    = 'Change main and sub job via direct packet.';
addon.link    = '';

require('common');
local chat = require('chat');

local jobs = {
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
    'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
};

local job_ids = {};
for id, abbr in ipairs(jobs) do
    job_ids[abbr] = id;
end

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function err(text)
    print(chat.header(addon.name):append(chat.error(text)));
end

-- Resolve a job abbreviation or numeric ID. Returns nil for an empty string.
local function parse_job(token)
    if token == nil or token == '' then
        return nil;
    end

    local id = tonumber(token);
    if id == nil then
        id = job_ids[token:upper()];
    end

    if id == nil or jobs[id] == nil then
        return false;
    end

    return id;
end

local function send_job_change(main, sub)
    -- Header: id 0x100, size 2 words (8 bytes) => 0x0500 little endian.
    local packet = { 0x00, 0x05, 0x00, 0x00, main, sub, 0x00, 0x00 };
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x100, packet);
end

local function change_jobs(main_token, sub_token)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local cur_main = player:GetMainJob();
    local cur_sub  = player:GetSubJob();

    if cur_main == 0 then
        err('Player data not loaded.');
        return;
    end

    local main = parse_job(main_token);
    local sub  = parse_job(sub_token);

    if main == false then
        err(('Unknown main job: %s'):format(main_token));
        return;
    end
    if sub == false then
        err(('Unknown sub job: %s'):format(sub_token));
        return;
    end
    if main == nil and sub == nil then
        err('Usage: /jc MAIN/SUB, /jc MAIN, or /jc /SUB');
        return;
    end

    -- Work out the end state the server will produce. Main is applied first and
    -- swaps with the sub if the new main matches the current sub.
    local final_main = main or cur_main;
    local final_sub  = cur_sub;
    if main ~= nil and main == cur_sub then
        final_sub = cur_main;
    end

    if sub ~= nil and sub == final_main then
        err('Main job and sub job cannot be the same.');
        return;
    end

    -- Only unlocked jobs have a level; the server rejects anything else.
    for _, id in ipairs({ main, sub }) do
        if id ~= nil and player:GetJobLevel(id) == 0 then
            err(('%s is not unlocked.'):format(jobs[id]));
            return;
        end
    end

    -- Zero out anything that would not actually change.
    local send_main = (main ~= nil and main ~= cur_main) and main or 0;
    local send_sub  = (sub ~= nil and sub ~= final_sub) and sub or 0;
    if sub ~= nil then
        final_sub = sub;
    end

    if send_main == 0 and send_sub == 0 then
        msg(('Already %s/%s.'):format(jobs[cur_main], jobs[cur_sub] or '---'));
        return;
    end

    send_job_change(send_main, send_sub);
    msg(('Requesting %s/%s.'):format(jobs[final_main], jobs[final_sub] or '---'));
end

ashita.events.register('command', 'jobchange_command', function (e)
    local args = e.command:args();
    if #args == 0 then
        return;
    end

    local cmd = args[1]:lower();
    if cmd ~= '/jc' and cmd ~= '/jobchange' then
        return;
    end
    e.blocked = true;

    -- Accept "/jc WAR/NIN", "/jc WAR NIN", "/jc WAR" and "/jc /NIN".
    local main_token, sub_token;
    if args[2] ~= nil and args[2]:find('/', 1, true) then
        main_token, sub_token = args[2]:match('^([^/]*)/([^/]*)$');
        if main_token == nil then
            err('Usage: /jc MAIN/SUB, /jc MAIN, or /jc /SUB');
            return;
        end
    else
        main_token, sub_token = args[2], args[3];
    end

    change_jobs(main_token, sub_token);
end);
