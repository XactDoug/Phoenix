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

```
/dbox get <slot> [in|out]   Take the item in <slot>. Box defaults to in.
/dbox <slot> [in|out]       Shorthand for the above.
/dbox all [in|out]          Take everything currently sitting in the 8 cells.
/dbox list [in|out]         Print the contents of a box.
/dbox new                   Pull waiting deliveries into the free incoming cells.
/dbox work [in|out]         Send Work, loading that box's cells server side.
/dbox open <in|out>         Send PostOpen or DeliOpen by hand.
/dbox close                 Send PostClose, closing the box server side.
/dbox mode [queue|inject]   Show or change how packets are sent.
/dbox debug [on|off]        Print every 0x04D sent and every 0x04B received.
/dbox help                  Print the command list.
```

The delivery box window does not need to be open. What the server actually requires, from
`0x04d_pbx.cpp` and `dboxutils.cpp`, is:

* An allowed zone: in a Mog House, or a zone carrying the `AuctionHouse` or `Mogmenu` misc flag,
  or a GM character. Anywhere else and the packet is dropped with a warning in the map log.
* Not in a cutscene or event, not crafting, not fishing, not jailed. The validator blocks those.
* A box open server side, and for `Get`, cells loaded into that container. `PostOpen` or
  `DeliOpen` opens it and clears the container, `Work` fills it. The game does both when it
  displays a box, which is why `/dbox get` on its own works right after you have had the delivery
  window up.

Nothing is opened or realigned for you. If the server has nothing loaded, drive it yourself, one
packet per command:

```
/dbox open in
/dbox work in
/dbox get 1 in
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

`/dbox get` sends one packet and nothing else. `list`, `all` and `work` send `Work` first, because
that is what tells the addon which cells hold something. `open` and `close` send exactly the packet
they name.

`/dbox new` adds `Check`, to ask how many deliveries are queued behind the cells, then one `Recv`
per free cell. `Recv` is the packet that moves a waiting delivery into an empty cell, so
`/dbox all in` followed by `/dbox new` and `/dbox all in` again is how you empty a full box.

Before taking an item the addon checks free inventory space. Gil is exempt, since the server does
not need an inventory slot for currency.

## Things worth knowing

* **The delivery box window must be open.** The server rejects 0x04D outside a zone that allows the
  delivery box, and every command except the open commands needs a box open server side.
* **One container per character.** The server holds one open box at a time. `Work` for the other
  box repoints that container without changing what the client is displaying, and `Get` reads from
  whatever is loaded, so keep track of which box you last loaded.
* **Send mode.** `inject` is the default: `IPacketManager::AddOutgoingPacket`, the path most
  addons use. `queue` uses the game's own queue instead,
  `QueueOutgoingPacket(id, len, align, pparam1, pparam2, callback, args)`, which stamps the header
  itself. That call returns a bool and was observed returning false on a live client, sending
  nothing, which is why it is not the default. The addon checks the return value now, says so, and
  falls back to injection for that send.
* **Nothing happens on an empty cell.** The server stays silent when you `Get` a cell it has
  nothing loaded for, so a bare `/dbox get` on an unloaded box just times out after 3 seconds.

## When a command gets no reply

`/dbox debug on` prints every 0x04D as it leaves the client and every 0x04B that comes back.

* No outgoing line at all: the packet never left the client. That is a send path problem, not a
  server one. `inject` is the default for exactly this reason.
* Outgoing line, no reply, and the map log says `DBOX: <name> is trying to use the delivery box in
  a disallowed zone`: wrong zone.
* Outgoing line, no reply, and the map log says `Invalid GP_CLI_COMMAND_PBX packet from <name>`:
  the packet arrived and the validator rejected it; the message names the field.
* Outgoing line, no reply, nothing in the map log at all: the packet never reached the handler.
  That points at the sub packet sync check in `src/map/map_networking.cpp`.

## Tests

`tests/` holds a small harness that stubs the Ashita API and simulates the server's 0x04B replies,
including the validation rules from `0x04d_pbx.cpp`. It runs under any Lua 5.x:

```
lua5.4 tools/client/ashita/dbox/tests/test_flows.lua
lua5.4 tools/client/ashita/dbox/tests/test_timeouts.lua
```

These cover the packet fields and the command logic. They do not cover the client, so they are no
substitute for testing in the game.
