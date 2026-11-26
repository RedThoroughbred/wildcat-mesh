import Foundation

/// The in-app guide: works offline, in the field. Text supports **bold**.
struct GuideChapter: Identifiable, Hashable {
    enum Block: Hashable {
        case text(String)
        case steps([String])
        case tip(String)
        case warning(String)
        case terms([(String, String)])

        static func == (a: Block, b: Block) -> Bool { a.hashValue == b.hashValue }
        func hash(into h: inout Hasher) {
            switch self {
            case .text(let s), .tip(let s), .warning(let s): h.combine(s)
            case .steps(let s): h.combine(s)
            case .terms(let t): t.forEach { h.combine($0.0); h.combine($0.1) }
            }
        }
    }

    let id: String
    let title: String
    let symbol: String
    let summary: String
    let blocks: [Block]

    static func == (a: GuideChapter, b: GuideChapter) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Guide {
    static func chapter(_ id: String) -> GuideChapter? { chapters.first { $0.id == id } }

    /// The Fox Hunt chapter's opening. The Hunt game for 2 or 3 friends (Small Play) is in it
    /// only where the build shows the game.
    private static var huntIntro: [GuideChapter.Block] {
        guard Features.smallPlay else {
            return [.text("Find a radio by its signal alone. **Fox Hunt** with friends needs a Meshtastic node. On your own, hunt on either network: **Solo hunt** on Meshtastic, **Repeater hunt** on MeshCore.")]
        }
        return [
            .text("Find a radio by its signal alone. **Hunt** is for 2 or 3 friends: one hides up to three pieces, then you swap. **Fox Hunt** is one fox and any number of hunters. Both need a Meshtastic node to host. On your own, hunt on either network: **Solo hunt** on Meshtastic, **Repeater hunt** on MeshCore."),
            .text("**Hunt, for 2 or 3 friends**"),
            .text("The pieces are small Meshtastic nodes on batteries, each with a 4-digit code on its label. The hider's phone referees through the hider's node; hunters walk with their own nodes, or with just a phone."),
            .steps([
                "**Play → Hunt**. Tick up to three **Pieces to hide**, then pick **Rounds**, a **Time limit** and **How a find counts**. The QR button opens the invite: friends scan it to join (it adds WGHUNT to their node).",
                "Tap **Hide**. For each piece: write the **Label code** on it, walk, set it down, and tap **Hidden here** standing right next to it. Wildcat keeps the spot for pick-up and sets that piece's claim line from what your node hears beside it: a claim needs about that minus 14 dB, a few steps away.",
                "Back with your friends, tap **Start round 1**. Your node answers everyone's moves until every piece is found, the time runs out, or you **End round**.",
                "Hunting: the piece in focus is big (tap another to switch). Walk until it says **Close**, find the box, tap **Found it** and type the code, or **Claim by signal only** if the hider allowed it.",
                "**Round over**: whoever found the pieces picks them up and taps **Swap · you hide round 2** (typing each label code as they hide it). The other phone taps **Hunt round 2**. Fastest total time wins.",
            ]),
            .terms([
                ("Signal or code", "A find is standing right by a piece by radio, or its label code. Code only, or signal only, are the other choices."),
                ("Guide", "A friend with no node gets warmer or colder from the phone's GPS instead, marked \"guide\": in bands, never closer than about 25 m, from a spot the invite moves a little. They scan the QR once every piece is hidden, tap **Start my clock** at the go, and claim with the label code."),
                ("Times", "Each phone adds up the times it saw: the hider's phone times its round, a hunter's phone times its own finds from the GO, within a few seconds."),
            ]),
            .tip("Keep the app open while you referee a round: your node answers for every piece. If the app closes, open it again: **Hunt in progress** on Play takes you back."),
        ]
    }

    static let chapters: [GuideChapter] = [
        GuideChapter(id: "start", title: "Start here", symbol: "flag.checkered", summary: "What Wildcat is and what you need", blocks: [
            .text("Wildcat Mesh is one app for two kinds of LoRa mesh radio: **Meshtastic** and **MeshCore**. Your phone talks to your own Meshtastic / MeshCore node over Bluetooth; the node does the radio work. Connect one of each at the same time and the **Bridge** joins the two networks."),
            .terms([
                ("Play", Features.smallPlay
                    ? "Pick **Who's playing?** (just me, 2 of us, 3 or more) and the games that fit show first: Hunt, Geo Gifts, Daily Fox. Below: Fox Hunt, Solo hunt, Repeater hunt, My Mesh, and **Practice** while no radio is connected."
                    : "Games: Fox Hunt, Geo Gifts, Solo hunt, Repeater hunt, Daily Fox, My Mesh, and **Practice** while no radio is connected."),
                ("Messages", "Channel and direct chats on both networks, plus **People**."),
                ("Reticulum", "A third network, in beta: encrypted messages through an RNode, and the RNode's console."),
                ("Explore", "On **Play** and in the **≡ Menu**: Nodedex, achievements, Territory, coverage walks and today's Daily Fox."),
                ("Meshtastic / MeshCore", "One tab per network, laid out the same way: **This radio**, **Radio**, **Heard nearby**, **Channels** or **Chats**, and **Manage**."),
                ("≡ Menu", "Top right on every tab, for the whole app: **Bridge**, **Map (both networks)**, **Radio log**, **Firmware**, **Guide**, **Safety**, **About Wildcat Mesh**, **Den (base station)** and **Keep raw packets**."),
            ]),
            .steps([
                "You need a Meshtastic / MeshCore node with Bluetooth, or one of each. For MeshCore that means the **Companion** (Bluetooth) firmware. No account.",
                "Charge the node and close the official Meshtastic or MeshCore app.",
                "Open your node's tab: **Meshtastic → Find my node**, or **MeshCore → Find MeshCore nodes**.",
                "Brand-new node? Tap **Set up this node** on its tab.",
                "Say hi on **Messages**, then pick a game on **Play**.",
            ]),
            .text("The pill at the top left shows both radios: a light for each network that blinks when a packet is heard. Tap it to jump to either tab. The ? next to the menu opens this guide at the right chapter."),
            .tip("No radio yet? **Play → Practice** starts pretend Meshtastic and MeshCore radios on your phone, with made-up nodes, chats, a fox and a Den, and opens Fox Hunt. Nothing is transmitted. The practice fox's code is 4821. **End practice** on either network tab ends both; a real radio stays connected."),
        ]),
        GuideChapter(id: "connect", title: "Connecting", symbol: "antenna.radiowaves.left.and.right", summary: "Bluetooth, PINs, reconnecting", blocks: [
            .warning("A node talks to **one app at a time**. Close the official Meshtastic or MeshCore app first (swipe it away; for MeshCore, quit it on your Mac too)."),
            .text("**Meshtastic**"),
            .steps([
                "**Meshtastic tab → Find my node**, then tap yours in the list.",
                "If iOS asks for a PIN, use the one on the node's screen. Nodes without a screen usually use 123456.",
                "Connected when the tab shows your node's name. Next time, tap **Reconnect**.",
            ]),
            .text("**MeshCore**"),
            .steps([
                "The node must run MeshCore's **Companion** (Bluetooth) firmware.",
                "**MeshCore tab → Find MeshCore nodes**, then tap yours under **Found nearby**. Wildcat loads its contacts and channels.",
                "PIN: the same as Meshtastic. Next time, tap **Reconnect the last one**.",
            ]),
            .tip("Repeaters and room servers never show under **Found nearby**: they have no phone Bluetooth. They appear in **Contacts** once your node hears their advert."),
            .text("**Disconnect** only stops Wildcat listening. The node keeps running, and its chats stay on your phone: you can read them while disconnected, on both networks."),
            .text("Each radio keeps its own chat history on this phone, Meshtastic and MeshCore alike. Connect a different node and Messages shows that node's chats; the earlier node's stay saved and readable."),
        ]),
        GuideChapter(id: "messages", title: "Messages", symbol: "bubble.left.and.bubble.right", summary: "Both networks, ticks, retries, size limits", blocks: [
            .text("Chats are grouped by the radio they travel through: **amber** is Meshtastic, **blue** is MeshCore. Filter with **All**, **MeshCore**, **Meshtastic** or **Direct**, use **Search chats**, and tap + for a **New message**."),
            .text("Every radio has its own chat history, on both networks: the list shows the connected node's chats, and with nothing connected, the last node's as **Saved chats**, read-only, with that node named. Switching nodes switches chats; earlier nodes' chats stay readable under **Other radios**. A Meshtastic channel is known by its name and key, so it keeps its chat when it moves slot."),
            .terms([
                ("Clock", "Sending."),
                ("One tick", "Sent. On Meshtastic, a neighbour repeated it: it's out on the mesh."),
                ("Green double tick", "Delivered: the person confirmed it (direct messages, both networks)."),
                ("Heard by 2 repeaters", "MeshCore channel: that many repeaters were heard passing it on."),
                ("No repeater heard it", "MeshCore channel: nothing was heard passing it on. Try again, or from higher ground."),
                ("Red mark", "Not sent, with the reason. Tap **Retry**, or long-press and choose **Send again**."),
            ]),
            .text("**Meshtastic**"),
            .text("A direct message waits for the other node to confirm it. Long-press a message to **Reply** or **React**."),
            .text("**MeshCore**"),
            .text("A direct message that isn't confirmed is sent again by itself, up to 3 tries; the last try floods the whole mesh in case the route changed. If every try fails, it shows why, with **Retry**. A confirmation that arrives late still counts. Room server posts show who wrote them."),
            .text("Under each received message: hops (\"direct\", \"2 hops\") and signal. \"Through the internet\" (MQTT, Meshtastic) means it didn't arrive by radio."),
            .text("**Long-press** any message for **Copy**, **Show raw packet**, **Send again**, **Report…** and **Block**. To see a packet's bytes, turn on **Keep raw packets** (≡ **Menu**) first."),
            .text("**People** lists everyone your radios know on both networks, with the same person merged across them."),
            .tip("Each message is one radio packet: at most 200 bytes on Meshtastic and 133 bytes on MeshCore. A counter appears near the limit. Short messages travel furthest."),
        ]),
        GuideChapter(id: "meshtastic", title: "Meshtastic tab", symbol: ReticulumStyle.symbol, summary: "Status, nodes, map, traceroute", blocks: [
            .text("Both network tabs share one layout. This is the Meshtastic one; the MeshCore chapter covers the other."),
            .terms([
                ("This radio", "Battery, channel use, signal and uptime, with keys for **Link**, **Bridge**, **GPS** and **Setup** (it reads **Region!** until the node has a region)."),
                ("Radio", "Region, preset, frequency slot, hops and power. **What's this?** opens Channels and keys."),
                ("Heard nearby", "The latest nodes, with **All nodes** and the **Mesh map**."),
                ("Channels", "Up to 8. Wildcat warns you if there's no WGHUNT hunt channel."),
                ("Manage", "**My Mesh**, **Map (both networks)**, **Node settings** (**Set up this node** on a new node) and **Bridge**."),
            ]),
            .steps([
                "**All nodes**: filter **All**, **Direct** or **Favorites**, or search. Signal bars mean heard directly; relayed nodes show their hops.",
                "Tap a node for battery, voltage, channel use, path, position and raw fields (**Copy all**).",
                "**Trace the route** shows every hop out and back with the signal at each. Once per 30 s: it costs airtime.",
                "**Star** keeps it at the top. **My Mesh** marks it as yours. **Block** hides it. **Remove from node database** makes your node forget it until it's heard again.",
                "**Mesh map**: tap a pin for **Message** or **Trace**.",
            ]),
            .tip("Not connected? The tab still shows your last node, its channels and who it heard."),
        ]),
        GuideChapter(id: "meshcore", title: "MeshCore tab", symbol: "dot.radiowaves.left.and.right", summary: "Contacts, chats, maps, trace", blocks: [
            .text("MeshCore splits the jobs: companions (the radios you carry) never repeat; only **repeaters** and room servers forward messages. The first message to someone floods out; after that it takes the learned path."),
            .terms([
                ("This radio", "Battery, traffic and signal, with keys for **Link**, **Bridge**, **GPS** and **Advert** (announce your node so others can add you). A **Setup** key appears when the node still needs setting up. **Switch** disconnects to pick another node."),
                ("Radio", "Frequency, bandwidth (BW), spreading factor (SF), coding rate (CR) and power, with the MeshCore preset they match. Every radio you want to hear must match all four."),
                ("Heard nearby", "Nodes whose adverts your node heard, sorted by **Signal**, **Recent** or **Name**."),
                ("Chats", "This node's channels and direct chats."),
                ("Manage", "**My Mesh**, **Contacts**, **Map**, **Map (both networks)**, **Channels**, **Node settings** and **Bridge**."),
            ]),
            .steps([
                "**Contacts**: filter **All**, **People** or **Repeaters**. A node becomes a contact when your node hears its advert (with **Add contacts automatically** on). Removed contacts come back with their next advert.",
                "A node your node heard but didn't save can be added to the node from its page. Sending it a direct message adds it for you.",
                "**Map**: tap a node for bearing, distance, hops and signal, then **Message** or **Trace**.",
                "**Trace** (repeaters and room servers) sends a small packet along the route and back. Each radio notes how well it heard it: above 0 dB is comfortable, below −10 dB is at the edge.",
                "**Reset route** on a contact forgets the path and finds a new one.",
            ]),
            .tip("Shared positions put your node on other people's maps."),
        ]),
        GuideChapter(id: "rnode", title: "RNode (Reticulum)", symbol: "circle.hexagongrid", summary: "Pair, read and tune a Reticulum LoRa modem", blocks: [
            .text("An **RNode** is a LoRa modem for the **Reticulum** network (Mark Qvist's encrypted mesh). It isn't a Meshtastic or MeshCore node: it has no chat of its own and no nodes it hears; a computer or phone running Reticulum drives it. Wildcat's **RNode console** reads it and tunes it over Bluetooth, and **Reticulum (beta)** uses it to send and receive messages (next chapter)."),
            .text("Find the console in **≡ Menu → RNode console**, on the **Reticulum** tab, in either tab's **Manage**, or in the radios pill's sheet (third row)."),
            .warning("An RNode talks to **one host at a time**. Quit Reticulum (rnsd, Sideband, MeshChat) on your computer before connecting from the phone, and start it again after you disconnect."),
            .text("**Pairing the first time** (most RNodes have no screen to show a PIN)"),
            .steps([
                "Plug the RNode into a computer and run **rnodeconf -p <port>**. It opens pairing for **35 seconds** and prints “Bluetooth pairing PIN is: 123456”.",
                "Within those 35 seconds, **RNode console → Find RNodes**, then tap the RNode. iOS asks for the PIN: type the six digits.",
                "The RNode drops the link once right after pairing; Wildcat reconnects by itself and reads it.",
                "Next time, tap **Reconnect**: a paired phone needs no PIN. Boards with a screen show the PIN on it; a pairing button does what rnodeconf -p does.",
            ]),
            .text("**The console.** The device card shows what **rnodeconf --info** shows: product and band (for example RAK4631 779–928 MHz), firmware, serial, modem chip, max TX power and the EEPROM signature state (Wildcat checks the checksum and that a signature is there; rnodeconf validates it with its keys). **Radio settings** are frequency, bandwidth, spreading factor, coding rate and TX power: each is written to the RNode at once and shown as the RNode reports it back. They last until the RNode reboots. **Reticulum (beta)** starts with the settings you made here."),
            .tip("All four radio settings (frequency, bandwidth, SF, CR) must match the other RNode **exactly**, or neither hears the other. Use a frequency you're allowed to use where you are."),
            .text("**Signal** shows what the modem hears while its radio is on: RSSI now, the noise floor, airtime and channel load, and the last packet's RSSI and SNR. The console only listens; it never transmits. Reticulum (beta) does, once you start it. **Power** shows the battery and temperature when the board reports them (many report nothing on USB power)."),
            .text("**Heard on air** lists every Reticulum packet the RNode hears, newest first: when, how loud, and what its header says. **Announce** (a destination telling the network it exists), **Data** (encrypted to its destination), **Path request**, **Link request** and **Proof**, with the destination's address (<53802fdd…>), how many **hops** it has come and whether a transport node passed it on. **Announcers** groups the announces by destination. Tap a packet for its bytes, with the header picked out."),
            .tip("Wildcat reads only the header; the contents are encrypted. **Access code** packets come from a Reticulum network with a name and passphrase set. The RNode can't hear Meshtastic or MeshCore: it listens on Reticulum's own sync word, on its own settings."),
        ]),
        GuideChapter(id: "reticulum", title: "Reticulum (beta)", symbol: ReticulumStyle.symbol, summary: "Encrypted messages over your RNode or the internet", blocks: [
            .text("**Reticulum (beta)** is a third network in Wildcat, next to Meshtastic and MeshCore. It sends end-to-end encrypted text messages over LoRa through your **RNode**, to people using Sideband, MeshChat, Columba or any other **LXMF** app. Wildcat runs the official Reticulum software (RNS and LXMF by Mark Qvist, unmodified) inside the app."),
            .warning("It is a beta. Read **What works?** on its screen before you rely on it: messages may not arrive while the phone is locked or Wildcat is closed."),
            .text("**Start**"),
            .steps([
                "Connect your RNode in the **RNode console** and set its radio: frequency, bandwidth, spreading factor, coding rate and TX power. They must match the people you want to reach, exactly.",
                "Open the **Reticulum** tab. It shows the settings it will transmit on. Type **Your name on Reticulum**, then tap **Start Reticulum**. The first start makes your address; it stays the same from then on.",
                "Tap **Announce**. That tells everyone in range your address and name. Nobody can reply to you until an announce of yours has reached them.",
                "People appear under **People heard** when their announce reaches your RNode. Tap one to write, or tap **New** and paste an address someone gave you.",
            ]),
            .terms([
                ("Your address", "32 letters and digits, like <53802fdd…>. Tap it to copy and give it to people. It belongs to the identity on this phone."),
                ("Queued, Finding a path, Sending", "On its way. Over LoRa a message can take many seconds."),
                ("Delivered", "The other end proved it got the message."),
                ("Not delivered", "With the reason: **No path** (they haven't announced where your phone can hear them), **needs a stamp** (see below), or no answer."),
                ("Unverified", "A message from someone whose announce your phone hasn't heard, so its signature couldn't be checked. A message with a wrong signature is dropped."),
                ("stamps", "Some people only accept messages that carry a stamp, a small proof of work. Wildcat on iPhone can't make stamps yet, so you can't write to them. They can still write to you."),
            ]),
            .text("**Internet link (optional).** Reticulum also travels over the internet. Turn on **Internet link** on the Reticulum tab and type the address and port of a Reticulum node you choose: your own, a friend's, or a public one from the list the Reticulum project keeps (the link is on the card). With it you can reach people far outside radio range, and you can use Reticulum without an RNode."),
            .tip("Wildcat ships no node list and connects only to the address you type. The link works only while Wildcat is open. The node's operator can see your phone's internet address and when you are connected, but not your messages: they stay encrypted end to end. Your phone never relays other people's traffic, and never passes internet traffic onto your radio."),
            .text("**Stop** turns the RNode's radio off and gives it back to the console. Your address, the people heard and your conversations are kept. Start again any time, without closing the app."),
            .tip("Long-press a received message to **Block** its sender or **Report…** it. A blocked address disappears from every list and its messages are dropped before they are stored. The word filter (≡ Menu → Safety) covers Reticulum messages and names too."),
            .text("**Privacy.** Reticulum encrypts each message for its recipient, on your phone. Your identity key stays in this phone's Keychain: it is not in backups and does not move to a new phone. An announce puts your address and the name you typed on air, in the clear, for anyone in range. With the internet link on, it also goes to the node you chose and on from there. Wildcat has no server and collects nothing."),
        ]),
        GuideChapter(id: "setup", title: "Setting up a node", symbol: "wand.and.stars", summary: "New nodes and node settings, both networks", blocks: [
            .text("A new Meshtastic / MeshCore node needs the right radio settings for where you are, and a name people will recognise. Both tabs offer **Set up this node**."),
            .text("**Meshtastic**"),
            .text("A new Meshtastic node won't transmit until it has a **Region**, the legal frequency band for your country. Until then, **Manage** shows **Set up this node** and the **Setup** key reads **Region!**."),
            .steps([
                "Connect it, then **Meshtastic tab → Set up this node**.",
                "Pick your **Region** (United States is 915 MHz), a long name and a short name (4 characters).",
                "Leave the **Role** on Client unless you know you want something else.",
                "Tap **Set up node**. It restarts to apply the region: reconnect after about 20 seconds.",
            ]),
            .text("**MeshCore**"),
            .text("A MeshCore node transmits straight away, but only radios on the same preset hear it. A **Setup** key on the MeshCore tab offers setup when the node still has its default name or a radio that matches no MeshCore preset."),
            .steps([
                "**MeshCore tab → Node settings → Set up this node**, or tap the **Setup** key.",
                "**Radio**: pick the preset your local mesh uses, from MeshCore's own list. Wildcat suggests one for your country (**USA** is 910.525 MHz, BW 62.5, SF 7, CR 5). **Keep this node's settings** leaves the radio alone.",
                "**Name**: what others see in their contacts and on maps, up to 31 bytes.",
                "**Position**: **Share where I am** sets it once to where your phone is now; or **Don't share my position**.",
                "**Channel**: **Create a private channel** for your group, or **Skip for now**.",
                "**Review**, choose whether to **Send a first advert**, then **Apply**. Show friends the new channel's QR code.",
            ]),
            .warning("A new preset retunes the node: it stops hearing anyone still on the old settings."),
            .text("**Node settings** (under **Manage** on each tab):"),
            .terms([
                ("Meshtastic", "**One tap** (**Make this node the fox**, **Make this node my Den**), **Name**, **Radio** (region, preset, transmit, frequency slot), **Role**, **Position**, **Channels** and **Firmware**. Region and role changes restart the node."),
                ("MeshCore", "**Setup**, **This node** (Bluetooth PIN), **Name**, **Radio** (preset, frequency, BW, SF, CR, power), **Position** (share in adverts, **Clear position**), **Adverts** (whole mesh or nodes in range only, **Add contacts automatically**), **Telemetry**, **Delivery** (**Extra delivery confirmations**), **Channels**, **Firmware** and **Danger zone** (**Reboot node**)."),
            ]),
            .terms([
                ("Client", "Meshtastic role: the normal choice for a node you carry."),
                ("Client (mute)", "Talks but never relays: for a second node right next to another."),
                ("Router", "Fixed, high infrastructure only. Not for handhelds."),
                ("Tracker", "Sends its position often, sleeps otherwise."),
            ]),
            .tip("No GPS on the node? On Meshtastic, turn on **Fixed position (use this phone's location)** while standing where it will live. On MeshCore, tap **Set position to where I am**."),
        ]),
        GuideChapter(id: "firmware", title: "Updating firmware", symbol: "cpu", summary: "Is there newer firmware? Both networks", blocks: [
            .text("Meshtastic and MeshCore publish new firmware every few weeks. Wildcat tells you when your Meshtastic / MeshCore node is behind. It never downloads or installs firmware itself."),
            .steps([
                "Open **Node settings → Firmware** on either network tab, or ≡ **Menu → Firmware** for both nodes at once.",
                "Tap **Check for updates**.",
                "**Up to date**, **Update available** (yours → the latest stable), **Newer than the latest stable** (a pre-release build), or newer than Wildcat has tested (it should still work).",
                "**Release notes** opens the official release page. **How to update** shows the ways for your board.",
            ]),
            .terms([
                ("nRF52 boards", "RAK4631, XIAO nRF52840, T114, T-Echo: copy your board's .uf2 file from the release onto the node over USB-C (double-tap reset), use the web flasher on a computer, or Nordic's **nRF Device Firmware Update** app over Bluetooth."),
                ("ESP32 boards", "Heltec V3, T-Beam and others: use the web flasher on a computer."),
                ("MeshCore", "Pick the **Companion** (Bluetooth) firmware for your board. USB, repeater and room-server builds don't talk to phones."),
            ]),
            .warning("Updating over Bluetooth? Close Wildcat first: a node talks to one app at a time."),
            .tip("The check happens only when you tap it. It downloads a public version list from the Wildcat website and sends nothing about you or your node."),
        ]),
        GuideChapter(id: "channels", title: "Channels and keys", symbol: "number", summary: "Create, share and join, both networks", blocks: [
            .text("A **channel** is a name plus an encryption key. Only nodes with the same key can read it. Each network has a public channel everyone nearby can read, plus private channels you share."),
            .text("**Meshtastic**"),
            .text("Up to 8 channels. Slot 0 is the **primary**: where the node's automatic broadcasts go (position, node info), and what sets its frequency. A private key is a random 256-bit key."),
            .steps([
                "Create: **Node settings → Channels → New private channel**.",
                "Share: tap the channel for its QR code, **Copy link** or **Share link**. **Share all channels as QR** shares the whole set.",
                "Join: **Import a Wildcat channel link or QR** → **Scan QR code** or **Paste** → **Apply**.",
            ]),
            .warning("Frequency rule: a Meshtastic node's frequency comes from its primary channel's name. Rename the primary and the node moves to a different frequency, and stops hearing everyone, unless its **Frequency slot** is pinned. Node settings shows the slot; Wildcat's fox links pin it for you."),
            .text("**MeshCore**"),
            .text("Up to the node's limit (40 on current firmware). Slot 0 is **Public**. A private key is a random 128-bit key."),
            .steps([
                "**MeshCore tab → Channels → Add a channel**, then pick **Create**, **Join** or **#Hashtag**.",
                "**Create**: a private channel with a fresh random key.",
                "**Join**: the channel's name plus its link or 32-digit key (**Paste** or **Scan QR**).",
                "**#Hashtag**: type a name like #hiking. The key comes from the name, so everyone who types the same #name meets there. Capitals matter: #Test and #test are different channels. Anyone who guesses the name can read it.",
                "Tap a channel to **Open chat**, share it (QR code, **Copy link**, **Share link** or **Copy key**), **Rename channel** (private ones; the key stays the same) or **Delete channel**.",
            ]),
            .tip("Meshtastic channels share as Wildcat's own links and QR codes (wildcat://channel), which friends scan in Wildcat. MeshCore channels share in the MeshCore app's own format, so they scan in Wildcat or the MeshCore app."),
        ]),
        GuideChapter(id: "repeaters", title: "Repeater admin", symbol: "key", summary: "Manage a MeshCore repeater over the air", blocks: [
            .text("A **repeater** is a MeshCore radio up high that passes messages along. It doesn't chat, but you can trace through it or manage it with its password. Room servers work the same way."),
            .steps([
                "Open it from **Contacts**, the **Map** or **Heard nearby**, and tap **Admin**.",
                "Enter the **Admin password** and tap **Log in**. It travels encrypted and only works when your node can reach the repeater. **Remember on this phone (Keychain)** saves it.",
                "No password? **Check status as a guest**.",
                "**Status**: battery, uptime, noise and packets relayed and heard, with **Refresh** and **Log out**.",
                "**Console**: commands, the same as over USB. Quick buttons cover common ones (ver, get radio, neighbors…).",
            ]),
            .warning("MeshCore only sends the first 15 characters of a password, so a longer one can't log in from a phone."),
            .tip("In practice mode any password works and nothing is sent."),
        ]),
        GuideChapter(id: "bridge", title: "The bridge", symbol: "arrow.left.arrow.right", summary: "Relay a channel between the two networks", blocks: [
            .text("Meshtastic and MeshCore radios can't hear each other. The bridge makes **your phone** relay one private Meshtastic channel ⇄ one private MeshCore channel, both ways."),
            .steps([
                "Make a private channel on each network (for example WGBRIDGE) and share it with friends on that side. The two keys don't need to match: each network keeps its own.",
                "Connect your Meshtastic node and your MeshCore node.",
                "Open ≡ **Menu → Bridge**, or **Bridge** under **Manage** on either network tab.",
                "Choose the **Meshtastic** channel and the **MeshCore** channel, then turn on **Bridge on**.",
                "Keep Wildcat open with both nodes connected. **Relayed** lists what crossed.",
            ]),
            .terms([
                ("⇄ Live", "Relaying now."),
                ("Waiting", "Turned on, but a node isn't connected (or is still loading). It goes live by itself."),
                ("Off", "Not relaying. If Wildcat turned it off, a note says why: a chosen channel was removed, renamed or became public."),
            ]),
            .text("Bridged messages show where they came from: \"Bridged from Meshtastic\" or \"Bridged from MeshCore\", with the sender's name. In other apps they start with [MT] or [MC] and the name."),
            .text("@name: start a message on the bridged channel with @name (\"@MAYA hello\") to send it privately to that one person on the other network. Their direct reply comes back to the sender."),
            .text("Geo Gifts and their opened receipts cross too. Blocked people never cross, either way. Long messages are cut to fit the other network."),
            .warning("Public channels can't be bridged. A public channel belongs to everyone nearby; bridging it would push your traffic onto their mesh. That includes MeshCore's Public channel and any Meshtastic channel with the default key."),
            .tip("The node that transmits a bridged message won't show it on its own screen. Another radio on that channel receives it: check from a second radio, or look at **Relayed**."),
        ]),
        GuideChapter(id: "mymesh", title: "My Mesh", symbol: "checkmark.seal", summary: "Every radio you own", blocks: [
            .text("**My Mesh** (on Play, and under **Manage** on both network tabs) lists your Meshtastic / MeshCore radios: what each one does, its battery, and when it was last heard."),
            .steps([
                "A radio joins when this phone connects to it, or when you log in to a repeater as admin. You can also tap **My Mesh** on a node's or contact's page.",
                "Tap a radio for **What it does**, its **Latest status** and its radio settings.",
                "**Remove from My Mesh** changes nothing on the radio.",
                "**How your mesh works** explains how each network carries messages.",
            ]),
        ]),
        GuideChapter(id: "foxhunt", title: "Fox Hunt", symbol: "scope", summary: "Find a hidden node by its signal", blocks: huntIntro + [
            .text("**Fox Hunt, any number of hunters**"),
            .text("Needs a Meshtastic node: hunt moves travel on its WGHUNT channel. One node is hidden: the **fox**, with a 4-digit code written on it. **Hunters** walk with their own nodes and phones. The host's phone referees over the radio."),
            .text("**Join**"),
            .steps([
                "Scan the host's QR code with the iPhone Camera, or **Play → Fox Hunt → Scan a host's QR**. Wildcat adds the hunt channel to your node if needed and joins. (Or type the **Hunt code** and **Your name** and tap **Join**.)",
                "Walk. The signal rises as your own radio hears the fox louder: warmer or colder. **Ticks** taps faster as you get closer.",
                "Once the hunt starts, the referee answers with warmer or colder and, after enough readings, a bearing. **Ping now** asks for a fresh reading.",
                "Find the box, tap **Found it**, type the code and tap **Claim the find**.",
            ]),
            .text("**Host**"),
            .steps([
                "**Play → Fox Hunt → Host from this phone**. Your node needs WGHUNT (making a fox creates one).",
                "Pick the **Fox node**. The **Code written on the fox** starts as a random one: write it on the fox, or type your own. Choose **How a find counts** and a **Time limit**, then **Open the lobby**.",
                "Hunters scan the QR code, or you **Share invite link**. To play too: **Hunt too, on this phone**.",
                "Tap **Start the hunt**. It ends when the time limit runs out, when everyone has found the fox, or when you tap **End hunt**. If the app closes mid-hunt, open it again: **Hunt in progress** on Play takes you back to the board.",
            ]),
            .terms([
                ("Code / Signal / Either", "A find needs the code, or getting very close by radio (good for kids), or either."),
                ("Place points", "100 / 70 / 50 for 1st to 3rd, then 30."),
                ("+50 RF witnessed", "The fox's own radio relayed your claim: you were right there."),
                ("+25 RF attested", "Your node heard the fox strongly in the last 5 minutes."),
            ]),
            .warning("Only **direct** radio counts. Relayed or internet readings never do. Five wrong codes lock you out."),
            .text("**On your own**"),
            .text("**Meshtastic**"),
            .text("**Play → Solo hunt** hunts any node your radio hears, by its signal, with no referee."),
            .text("**MeshCore**"),
            .text("**Play → Repeater hunt**: pick a repeater and find it by its signal. Every packet it sends (adverts, relayed traffic, answers to **Ping now**) moves the scope. If it shares its position, the distance shows within 150 m. Tap **Found** when you see it."),
            .tip("With a Den paired, **Host on the Den** lets it referee a hunt with friends. Only hunt repeaters you're allowed to walk up to: many sit on private property."),
        ]),
        GuideChapter(id: "fox", title: "Make a fox", symbol: "pawprint", summary: "One tap turns a spare node into the fox", blocks: [
            .text("Needs a Meshtastic node: a MeshCore fox can't be made yet (on MeshCore, hunt a repeater instead). Any small Meshtastic node on a battery makes a great fox. Use a spare node, not the one you carry."),
            .steps([
                "Connect **your everyday node** once (the one with WGHUNT). Wildcat remembers the hunt channel and your mesh's frequency.",
                "Connect the spare node → **Meshtastic tab → Node settings → Make this node the fox** → **Make it the fox**.",
                "It restarts once. Hunters scan the QR code shown afterwards (**Share the hunt channel**).",
                "Write a 4-digit code on it and hide it.",
            ]),
            .terms([
                ("Hunt channel only", "Its only channel, pinned to your mesh's frequency so everyone hears it."),
                ("Low power", "10 dBm: walking closer really changes the signal."),
                ("Location hidden", "GPS off and no fixed position: hunters can't just read it off the map."),
                ("Heartbeat", "Battery and uptime once an hour, no location. To hear the fox, ping it: it answers every ping."),
            ]),
            .tip("No hunt channel yet? **Make a new hunt channel** on the fox screen, then share its QR code with hunters."),
            .warning("Put the fox somewhere public and safe, never on private property."),
        ]),
        GuideChapter(id: "explore", title: "Daily Fox and Explore", symbol: "map", summary: "Daily Fox, Nodedex, Territory", blocks: [
            .text("Everything in this chapter **needs a Meshtastic node** for now: it's built from the Meshtastic nodes your radio (or your Den) hears. With only a MeshCore node, try **Repeater hunt** on Play."),
            .text("**Daily Fox**: each day one real Meshtastic node is your fox. It's picked from nodes heard over the air in the last 3 days, that share a position, at least 300 m from you and inside **Search within** (2, 5, 10 or 25 km)."),
            .steps([
                "**Play → Daily Fox → Start the hunt**. Before you start, **Other fox** picks a different one.",
                "Find it by its signal, including traffic it relays. Its location stays hidden until you stand within 100 m: that's the find.",
            ]),
            .terms([
                ("Ping", "Asks the fox for a fresh reading (a traceroute). Once per 30 s: it costs airtime."),
                ("Hint", "−150 points each: first how far, then which way."),
                ("Give up", "**Reveal it** shows where it was. A new fox appears tomorrow."),
                ("Streak", "Days in a row with a found fox."),
            ]),
            .terms([
                ("Nodedex", "Every node your radio hears directly. Rarity is the longest distance you heard it from: 1 km uncommon, 5 km rare, 15 km legendary (distance needs the node's position from a Den)."),
                ("Achievements", "Firsts and milestones."),
                ("Territory", "Hexagons you've covered on coverage walks. **Fog** hides the rest; **Frontier** is your farthest reach from the Den in 16 directions. Needs a Den."),
            ]),
            .warning("Foxes are other people's nodes, often on private property. Finding it within 100 m means you can do it from the street."),
        ]),
        GuideChapter(id: "gifts", title: "Geo Gifts", symbol: "gift", summary: "Messages that only open at a place", blocks: [
            .text("Leave a message that only opens when someone stands on the spot. No server: the message is locked with the place itself, so even the app can't read it anywhere else. Works on Meshtastic / MeshCore, or with no radio at all."),
            .steps([
                "**Play → Geo Gifts → Leave a gift**.",
                "Tap the map to drop the spot, or **Use where I'm standing**.",
                "Write the message (up to 140 bytes) and an optional teaser they see before it opens.",
                "Pick **Opens within** (about 30, 100 or 300 m) and a **Hint area**: the exact spot, or a 300 m, 1 km or 3 km circle.",
                "Under **Send**, pick a Meshtastic / MeshCore channel, one person (Meshtastic), or a link or QR code (no radio). Tap **Leave it**.",
            ]),
            .text("A gift you receive waits locked in **For me**, with the hint on a map. Walk there with Wildcat open: it opens by itself, and the sender gets an opened receipt over the mesh. **I left** lists your gifts and which were opened. Got a link? **Open a gift link from the clipboard**."),
            .tip("MeshCore packets are smaller: keep the message and teaser short. Scavenger hunt: put the clue to the next spot inside each gift."),
            .warning("Phone GPS is usually within 5–15 m. Use the 100 m option under trees or between buildings."),
        ]),
        GuideChapter(id: "coverage", title: "Coverage walks", symbol: "figure.walk", summary: "Map where your mesh reaches", blocks: [
            .text("A coverage walk (or drive) maps where your node is heard. It **needs a Meshtastic node** and a paired Den."),
            .steps([
                "**Play → Explore → Coverage walk / drive**.",
                "Pick a **Channel** the Den also has (a private one is kinder) and how often: **Every** 5, 10 or 15 min (5 is the fastest: the mesh's airtime is shared). Tap **Start walk**.",
                "Walk or drive. Each beacon carries **no location**: the Den reports whether it heard it, and your phone pins the answer to where you were.",
                "Dots: the Den heard you (strong, ok or weak). Triangles: your node heard the Den. Black rings: dead spots. **Stop walk** to finish.",
            ]),
            .warning("Keep Wildcat open with the screen on: logging pauses when the phone locks."),
        ]),
        GuideChapter(id: "safety", title: "Safety", symbol: "hand.raised", summary: "Block, report, word filter", blocks: [
            .text("Messages travel radio to radio with no server, so moderation lives on your phone: ≡ **Menu → Safety**. It works the same on Meshtastic / MeshCore."),
            .terms([
                ("Block", "Long-press a message and choose **Block** (with their name), or block from **People**, a node's page or a MeshCore contact. Their messages disappear, you get no notifications from them, and the bridge won't relay them."),
                ("Per network", "Blocking a Meshtastic node also makes your node ignore it. MeshCore channel messages carry only a name, so a MeshCore block can be by name alone."),
                ("Report", "Long-press a message → **Report…** (or **Report and block**). Wildcat opens an email to the Wildcat team with the message filled in. Nothing is sent unless you send it. No mail app? **Copy report**."),
                ("Word filter", "**Hide strong language** is on by default: slurs and strong swearing in messages you receive show as •••• until you tap. Notifications never show them."),
                ("Unblock", "In **Safety**, tap **Unblock** next to the person."),
            ]),
        ]),
        GuideChapter(id: "den", title: "The Den (optional)", symbol: "house.lodge", summary: "An always-on base station for Meshtastic", blocks: [
            .text("A Den is optional: every game works with just phones and nodes. It **needs a Meshtastic node**; MeshCore doesn't use one."),
            .terms([
                ("Den Lite", "No computer: **Node settings → Make this node my Den** → **Make it my Den**, for a Meshtastic node that stays plugged in at home or up high. It relays for everyone, holds its position (where your phone is now), sends a heartbeat and, on ESP32 boards with PSRAM, stores messages for nodes that were away."),
                ("Full Den", "A Pi or computer with a Meshtastic node plugged in, running the Wildcat Den software. It adds history, coverage maps, Territory and refereed hunts."),
            ]),
            .steps([
                "Put the Den and your phone on the same Wi-Fi, or the same Tailscale network.",
                "≡ **Menu → Den (base station) → Enter Den address**, e.g. 100.x.y.z:5050.",
                "To send through the Den, add its **Operator password** in **Den settings**.",
            ]),
        ]),
        GuideChapter(id: "manners", title: "Airtime manners", symbol: "hourglass", summary: "Be a good mesh neighbour", blocks: [
            .text("Everyone shares the same slow radio channel. Every packet you send is airtime others can't use."),
            .steps([
                "Keep chats short; don't flood the public channel.",
                "Use pings, traces and adverts sparingly (the app limits pings).",
                "Run games, bridges and coverage beacons on a **private** channel.",
                "Use the right band for your country: the **Region** on Meshtastic, your local preset on MeshCore. It's the law.",
            ]),
        ]),
        GuideChapter(id: "trouble", title: "Troubleshooting", symbol: "wrench.and.screwdriver", summary: "When something doesn't work", blocks: [
            .terms([
                ("Can't connect", "Close the official Meshtastic or MeshCore app (for MeshCore, on your Mac too). Toggle Bluetooth, or restart the node. **Radio log** (≡ Menu) shows connection steps and bridge decisions for both radios."),
                ("MeshCore node not found", "It needs the **Companion** (Bluetooth) firmware. Repeater and room-server firmware has no phone Bluetooth."),
                ("PIN", "Use the PIN on the node's screen, or 123456 on nodes without one. On MeshCore you can change it in **Node settings** (**Set PIN**)."),
                ("Bluetooth or location off", "Wildcat works with what you allow. Without Bluetooth it can't reach a node, but practice mode still works. Fox Hunt, Daily Fox, Geo Gifts and coverage walks use your location while the app is open; without it, just those parts are unavailable. Your choices live in the Settings app if you ever want to change them."),
                ("Nobody hears me (Meshtastic)", "Region set? **Transmit enabled**? Same preset and frequency slot as your mesh (**Node settings → Radio**)?"),
                ("Nobody hears me (MeshCore)", "Frequency, bandwidth, SF and CR must match the radios around you: run **Set up this node** and pick your local preset. Send an advert so others can add you."),
                ("MeshCore message failed", "Wildcat already tried 3 times. Try **Reset route** on the contact, move higher, then **Retry**."),
                ("Settings didn't save", "\"The node didn't answer\": reconnect and try again. Meshtastic region and role changes restart the node."),
                ("Can't hear the fox", "Is WGHUNT on your Meshtastic node? Does the fox answer a ping? Is it on the same frequency slot?"),
                ("Game says it needs a radio", "It names the network it needs. Fox Hunt with friends, Daily Fox, Explore and the Den need a Meshtastic node; Repeater hunt needs a MeshCore node."),
                ("Bridge shows Waiting", "It's on, but a node isn't connected yet. Connect both and keep Wildcat open."),
                ("Bridge shows Off", "It was turned off, or Wildcat turned it off because a chosen channel was removed, renamed or became public. **Bridge** says why: choose the channels again."),
                ("My bridged message isn't on my node", "Normal: the node that transmits it doesn't show it. Check from another radio on that channel."),
                ("Den offline", "Is Tailscale connected on your phone? Is the Den running?"),
                ("Firmware check failed", "**Check for updates** needs the internet for that one tap. Try again later; the last answer stays. To update, **How to update** links to the official flashers."),
            ]),
        ]),
    ]
}
