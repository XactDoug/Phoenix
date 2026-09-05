local h = dofile((arg and arg[0] and arg[0]:match('^(.*)[/\\][^/\\]*$') or '.') .. '/harness.lua');
local S = h.server;
local out, e;
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

out = h.run('/dbox');                 show('help', out);
out = h.run('/dbox list in');         show('list in', out);  show('packets', packets());
out = h.run('/dbox list out');        show('list out', out); show('packets', packets());
out = h.run('/dbox get 1');           show('get 1 (incoming, first cell)', out); show('packets', packets());
out = h.run('/dbox 6 in');            show('shorthand slot 6', out);
out = h.run('/dbox get 2 out');       show('get 2 out', out); show('packets', packets());
out = h.run('/dbox get 4 in');        show('get empty slot', out);
out = h.run('/dbox new');             show('new', out); show('packets', packets());
out = h.run('/dbox list in');         show('list in after new', out);
out = h.run('/dbox all in');          show('all in', out);
out = h.run('/dbox close');           show('close', out);
out = h.run('/dbox mode inject');     show('mode inject', out);
out = h.run('/dbox list in');         show('list in via inject mode', out);
out = h.run('/dbox mode queue');      show('mode queue', out);
out = h.run('/dbox get 9');           show('bad slot', out);
out = h.run('/dbox get 1 sideways');  show('bad box', out);

-- inventory full behaviour: gil should still come through
S.boxes[1].cells[0] = { itemid = 4096, stack = 1, person = 'Sender1' };
S.boxes[1].cells[3] = { itemid = 65535, stack = 900, person = 'AH' };
h.set_inventory(30, 30);
out = h.run('/dbox all in');          show('all in with full inventory', out);
h.realprint('DONE');
