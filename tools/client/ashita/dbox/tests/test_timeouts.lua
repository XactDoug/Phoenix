local h = dofile((arg and arg[0] and arg[0]:match('^(.*)[/\\][^/\\]*$') or '.') .. '/harness.lua');
local S = h.server;
local function show(l, o) h.realprint('--- ' .. l); for _, x in ipairs(o) do h.realprint('    ' .. x); end end

S.boxes[1].cells[0] = { itemid = 4096, stack = 1, person = 'Sender1' };

local t = os.time();
S.drop_next_get = true;
show('get with no Get reply (expect timeout message)', h.run('/dbox get 1'));
h.realprint('    elapsed ~' .. (os.time() - t) .. 's');

S.deaf = true;
t = os.time();
show('server silent (expect open failure)', h.run('/dbox list out'));
h.realprint('    elapsed ~' .. (os.time() - t) .. 's');
h.realprint('DONE');
