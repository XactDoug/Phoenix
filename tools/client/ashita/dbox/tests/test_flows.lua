local h = dofile((arg and arg[0] and arg[0]:match('^(.*)[/\\][^/\\]*$') or '.') .. '/harness.lua');
local S = h.server;
local function show(label, lines)
    h.realprint('--- ' .. label);
    for _, l in ipairs(lines) do h.realprint('    ' .. l); end
end
local function packets()
    local t = {};
    for _, p in ipairs(S.sent) do
        t[#t + 1] = ('cmd=%02X box=%d slot=%d iwn=%d'):format(p.command, p.box, p.slot, p.itemWorkNo);
    end
    return t;
end

-- seed the boxes
S.boxes[1].cells[0] = { itemid = 4096, stack = 1,  person = 'Sender1' };
S.boxes[1].cells[2] = { itemid = 65535, stack = 50000, person = 'AH' };
S.boxes[1].cells[5] = { itemid = 1234, stack = 12, person = 'Sender2' };
S.boxes[1].queue    = { { itemid = 777, stack = 1, person = 'Later' }, { itemid = 778, stack = 2, person = 'Later2' } };
S.boxes[2].cells[1] = { itemid = 999,  stack = 3,  person = 'Target' };

show('help', h.run('/dbox'));

-- The game has the incoming box open and its cells loaded, as it would after the player
-- opened the delivery window. get must send nothing but the Get packet.
S.opened = 1;
S.container = S.boxes[1].cells;
show('get 1 in (box already open)', h.run('/dbox get 1 in'));
show('packets', packets());

show('shorthand slot 6', h.run('/dbox 6 in'));
show('packets', packets());

-- A slot the server has nothing loaded for: no reply, and the addon says so.
show('get an empty slot', h.run('/dbox get 4 in'));
show('packets', packets());

-- Asking for the other box without opening it: the server still answers Get from the
-- container it has loaded, which is the incoming one. This is the raw behaviour now.
show('get 2 out while incoming is loaded', h.run('/dbox get 2 out'));
show('packets', packets());

-- Explicit open, then the outgoing box works as expected.
show('open out', h.run('/dbox open out'));
show('packets', packets());
show('list out', h.run('/dbox list out'));
show('get 2 out', h.run('/dbox get 2 out'));
show('packets', packets());

show('open in', h.run('/dbox open in'));
show('list in', h.run('/dbox list in'));
show('packets', packets());
show('new', h.run('/dbox new'));
show('packets', packets());
show('all in', h.run('/dbox all in'));
show('packets', packets());
show('close', h.run('/dbox close'));

show('bad slot', h.run('/dbox get 9'));
show('bad box', h.run('/dbox get 1 sideways'));
show('open with no box named', h.run('/dbox open'));

-- inventory full: gil still comes through, the rest is left alone
S.boxes[1].cells[0] = { itemid = 4096, stack = 1, person = 'Sender1' };
S.boxes[1].cells[3] = { itemid = 65535, stack = 900, person = 'AH' };
h.set_inventory(30, 30);
h.run('/dbox open in');
show('all in with a full inventory', h.run('/dbox all in'));

-- The raw sequence, one packet per command: open, work, get.
S.boxes[1].cells[6] = { itemid = 4321, stack = 1, person = 'Sender3' };
show('open in', h.run('/dbox open in'));
show('get 7 before Work (server has nothing loaded)', h.run('/dbox get 7 in'));
show('work in', h.run('/dbox work in'));
show('packets', packets());
h.run('/dbox debug on');
show('debug get 7 after Work', h.run('/dbox get 7 in'));
h.run('/dbox debug off');
h.realprint('DONE');
