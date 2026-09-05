local h = dofile((arg and arg[0] and arg[0]:match('^(.*)[/\\][^/\\]*$') or '.') .. '/harness.lua');
local S = h.server;
local function show(l, o) h.realprint('--- ' .. l); for _, x in ipairs(o) do h.realprint('    ' .. x); end end

S.boxes[1].cells[0] = { itemid = 4096, stack = 1, person = 'Sender1' };

-- Nothing has loaded a box: the server drops Get and says nothing.
local t = os.time();
show('get with no box loaded (expect timeout message)', h.run('/dbox get 1'));
h.realprint('    elapsed ~' .. (os.time() - t) .. 's');

-- Box loaded, but the Get reply goes missing.
h.run('/dbox open in');
h.run('/dbox work in');
S.drop_next_get = true;
t = os.time();
show('get with the reply dropped', h.run('/dbox get 1'));
h.realprint('    elapsed ~' .. (os.time() - t) .. 's');

-- Server not answering at all.
S.deaf = true;
t = os.time();
show('server silent (expect Work failure)', h.run('/dbox list out'));
h.realprint('    elapsed ~' .. (os.time() - t) .. 's');
t = os.time();
show('server silent (expect open failure)', h.run('/dbox open out'));
h.realprint('    elapsed ~' .. (os.time() - t) .. 's');
h.realprint('DONE');
