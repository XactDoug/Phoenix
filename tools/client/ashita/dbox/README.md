# dbox (Ashita v4 addon)

Takes items out of the delivery box from a chat command, from either box, by slot number.
Written against this server's own delivery box code, not against a retail capture.

**Verify this against the retail client and a live capture before trusting it.** No packet
captures were used while writing it. The packet layout was taken from
`src/map/packets/c2s/0x04d_pbx.h`, the accepted field values from the validator in
`src/map/packets/c2s/0x04d_pbx.cpp`, and the behaviour of each command from
`src/map/utils/dboxutils.cpp`, cross checked against
[XiPackets 0x004D](https://github.com/atom0s/XiPackets/tree/main/world/client/0x004D).
Anything a private server does differently to retail will be inherited by this addon.

## Install

Copy the `dbox` folder into your Ashita v4 addons folder so you end up with:

```
<Ashita>/addons/dbox/dbox.lua
```

Then `/addon load dbox`, or add `/addon load dbox` to your Ashita script.

## Use

Stand at a delivery NPC (a Mog House moogle, an auction house, a residential area) and open the
delivery box window, then:

```
/dbox get <slot> [in|out]   Take the item in <slot>. Box defaults to in.
/dbox <slot> [in|out]       Shorthand for the above.
/dbox all [in|out]          Take everything currently sitting in the 8 cells.
/dbox list [in|out]         Print the contents of a box.
/dbox new                   Pull waiting deliveries into the free incoming cells.
/dbox close                 Send PostClose, closing the box server side.
/dbox mode [queue|inject]   Show or change how packets are sent.
/dbox help                  Print the command list.
```

`in` and `out` also accept `incoming`/`recv`/`1` and `outgoing`/`send`/`deli`/`2`.

Slots are numbered 1 to 8, matching the game window. On the wire that is `PostWorkNo` 0 to 7. If
you would rather type the wire numbers, so that what you type matches the server logs, set
`slot_base = 0` at the top of `dbox.lua`.

## What it sends

Every command is the client to server packet `GP_CLI_COMMAND_PBX` (0x04D), 0x20 bytes, with the
same fields the client uses. `/dbox get 1 in` sends `Get` with `BoxNo = Incoming` and
`PostWorkNo = 0`, which is exactly what the client's own delivery box does when you take the item
in the first cell.

Each command runs a short sequence and waits for the matching `GP_SERV_COMMAND_PBX_RESULT` (0x04B)
reply before moving on, rather than firing packets on a timer:

1. `PostOpen` (incoming) or `DeliOpen` (outgoing), skipped when the server already has that box
   open. The addon tracks this from the replies, including replies caused by the game itself.
2. `Work` for the box, which loads the 8 cells server side and tells the addon what is in them.
3. `Get` for each requested slot.

`/dbox new` adds `Check`, to ask how many deliveries are queued behind the cells, then one `Recv`
per free cell. `Recv` is the packet that moves a waiting delivery into an empty cell, so
`/dbox all in` followed by `/dbox new` and `/dbox all in` again is how you empty a full box.

Before taking an item the addon checks free inventory space. Gil is exempt, since the server does
not need an inventory slot for currency.

## Things worth knowing

* **The delivery box window must be open.** The server rejects 0x04D outside a zone that allows the
  delivery box, and every command except the open commands needs a box open server side.
* **Asking for the other box moves the window.** The server keeps one open container per character.
  If the window is showing the incoming box and you run `/dbox list out`, the addon sends
  `DeliOpen` and `Work` for the outgoing box, and the client will follow along. That is the same
  thing the game does when you switch tabs yourself, but it will look abrupt.
* **Send mode.** `queue` (the default) hands the packet to the game's own packet queue, so the
  client stamps a valid sync value on it. This server drops any sub packet whose sync is not
  greater than the session's last one, see the parse loop in `src/map/map_networking.cpp`. `inject`
  writes the packet through Ashita directly. If commands appear to do nothing, and nothing turns up
  in the map server log, try `/dbox mode inject` and compare.
* **Nothing happens on an empty cell.** The server stays silent when you `Get` an empty cell, so
  the addon checks the cell contents from the `Work` reply first and tells you rather than waiting
  out a timeout.

## Tests

`tests/` holds a small harness that stubs the Ashita API and simulates the server's 0x04B replies,
including the validation rules from `0x04d_pbx.cpp`. It runs under any Lua 5.x:

```
lua5.4 tools/client/ashita/dbox/tests/test_flows.lua
lua5.4 tools/client/ashita/dbox/tests/test_timeouts.lua
```

These cover the packet fields and the command logic. They do not cover the client, so they are no
substitute for testing in the game.
