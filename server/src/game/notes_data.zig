//! The found notes: every set and every note, as comptime tables. docs/LORE.md is the canon these
//! follow. Text in here ships to players. A note's index in `notes` is its bit in a player's
//! found set, so only ever append: never reorder or remove.

const data = @import("data.zig");

pub const Rarity = data.Rarity;

/// How a note is drawn: the client picks a paper for each. The tag name is the wire name.
pub const Form = enum { notebook, memo, email, chat, receipt, sticky, radio, poster, letter, review, card };

pub const SetId = enum { lantern, starlite, ordinary, containment, survey, hunger, zero, road };

/// Who can find (and read) the notes of a set.
pub const Audience = enum { both, human, zombie };

pub const SetRow = struct {
    id: SetId,
    name: []const u8,
    audience: Audience,
    /// The cosmetic title for completing the set.
    title: []const u8,
    blurb: []const u8,
};

pub const sets = [_]SetRow{
    .{ .id = .lantern, .name = "Project Lantern", .audience = .both, .title = "Keeper of the Lantern", .blurb = "What Halvorsen Biologics was building, and why it worked too well." },
    .{ .id = .starlite, .name = "The Starlite Diner", .audience = .both, .title = "Archivist of the Starlite", .blurb = "One night, one booth, one slice of pie." },
    .{ .id = .ordinary, .name = "Ordinary People", .audience = .both, .title = "Chronicler of Small Things", .blurb = "The end of the world, as it happened to people with errands." },
    .{ .id = .containment, .name = "Containment", .audience = .both, .title = "Keeper of the Cordon", .blurb = "Orders, logs and forms from the nine days it was supposed to hold." },
    .{ .id = .survey, .name = "The Survey", .audience = .human, .title = "Grid Reader", .blurb = "Grease pencil on paper maps, for whoever comes after." },
    .{ .id = .hunger, .name = "The Hunger", .audience = .zombie, .title = "Listener to the Fever", .blurb = "What is left, and what is still warm." },
    .{ .id = .zero, .name = "Patient Zero", .audience = .both, .title = "The One Who Knew", .blurb = "Someone was sick before the crash. Someone made sure no one knew." },
    .{ .id = .road, .name = "Along the Road", .audience = .both, .title = "Roadside Scribe", .blurb = "Signs and scraps from the places you stop to search." },
};

pub const Note = struct {
    /// Stable wire id, "<set>.<nn>".
    id: []const u8,
    set: SetId,
    title: []const u8,
    author: []const u8,
    date: []const u8,
    form: Form,
    rarity: Rarity,
    /// Only found at this kind of place (landmark caches).
    place: ?data.PlaceKind = null,
    body: []const u8,
};

pub const notes = [_]Note{
    // --- Project Lantern -------------------------------------------------------------------------
    .{
        .id = "lantern.01",
        .set = .lantern,
        .title = "It Will Not Die",
        .author = "Dr. Ilse Kessler, lab notebook, p. 41",
        .date = "Day −212",
        .form = .notebook,
        .rarity = .uncommon,
        .body =
        \\Plate 14, fourth passage out of the permafrost core, and it is STILL growing. At 5 degrees. At minus 2. In a dish I forgot over a long weekend and found on Monday looking smug.
        \\Tomas says I have to name it. I said naming things is how you get attached. I have been calling it "the bloom" in my head since Tuesday.
        \\Rat liver slice, no oxygen, nine days. Still pink. Still warm. I measured: 41 C, which is not a temperature a dead thing has any business being.
        \\Don't tell Halvorsen yet. They will want a slide deck.
        ,
    },
    .{
        .id = "lantern.02",
        .set = .lantern,
        .title = "Kickoff: Please Do Not Say Fungus",
        .author = "Gwen Aldridge, VP Strategy, Halvorsen Biologics",
        .date = "Day −190",
        .form = .memo,
        .rarity = .uncommon,
        .body =
        \\TO: Translational Group, Business Park Building C
        \\RE: PROJECT LANTERN (formerly Project Kessler Bloom; renamed because that sounds like a lawsuit)
        \\Team, the KB-7 licence is signed. Donor organs last six hours on ice. If KB-7 does what Dr. Kessler says, they last weeks. The market is enormous. I have said "enormous" in three meetings and the board has started to hum.
        \\Guidance for external materials:
        \\ - Do NOT use the word "fungus". Use "bioactive preservation matrix".
        \\ - Do NOT use the word "bloom".
        \\ - Do NOT say "it's alive". It is "viable".
        \\Lunch is provided. Please stop naming the samples.
        ,
    },
    .{
        .id = "lantern.03",
        .set = .lantern,
        .title = "Re: Request for Expedited Approval",
        .author = "Dr. P. Okafor, Research Ethics Board",
        .date = "Day −120",
        .form = .email,
        .rarity = .uncommon,
        .body =
        \\From: P. Okafor, Chair, Ethics Board
        \\To: I. Kessler
        \\Subject: Re: Re: Request for Expedited Approval (Human Tissue, Phase 1)
        \\Dr. Kessler,
        \\The Board has read your request. It is denied.
        \\"The tissue stayed warm" is not a safety endpoint. Neither is "it leaned toward the heating pad." Please do not describe a sample as "keen" in a document that will be read aloud.
        \\Come back with a containment plan, a kill step, and an explanation for the rat that was found on the wrong side of its cage on Tuesday.
        \\With respect, and some alarm,
        \\P. Okafor
        ,
    },
    .{
        .id = "lantern.04",
        .set = .lantern,
        .title = "Glove",
        .author = "Tomas Reyes, to Danny",
        .date = "Day −63",
        .form = .chat,
        .rarity = .rare,
        .body =
        \\Tomas: dude the liver is WARM
        \\Tomas: like warm warm. i held it. i know i shouldnt have
        \\Danny: why would you hold it
        \\Tomas: it was nice. its like holding a hand
        \\Danny: that is the worst sentence ive ever received
        \\Tomas: my glove tore a bit. tiny. its fine
        \\Danny: tell Kessler
        \\Tomas: she'll write it up and then i'll never touch the good plates again
        \\Tomas: its FINE. i washed it. went to lunch. i'm starving btw
        ,
    },
    .{
        .id = "lantern.05",
        .set = .lantern,
        .title = "The Pig Heart Leans",
        .author = "Dr. Ilse Kessler, lab notebook, p. 88",
        .date = "Day −41",
        .form = .notebook,
        .rarity = .rare,
        .body =
        \\Valve tissue from a donor pig heart, kept on KB-7 for nineteen days. It should be mush.
        \\It beats. Faintly, but it beats, in a dish, with no one asking it to.
        \\Test: warm pad on the left, cold on the right. It leaned left. Moved the pads. It leaned left again. It is not choosing the pad. It is choosing the WARM.
        \\Ran it twelve times. Twelve for twelve. Went home and sat in the car for a while.
        \\This is not preservation. A preserved thing sits there. This wants something.
        ,
    },
    .{
        .id = "lantern.06",
        .set = .lantern,
        .title = "Chain of Custody: Cooler L-C",
        .author = "Halvorsen Logistics, shipping manifest",
        .date = "Day −1",
        .form = .memo,
        .rarity = .rare,
        .body =
        \\MANIFEST #LNT-0417 -- COLD CHAIN, HAND CARRY
        \\Item: 1 x cooler, Lantern-C, six sealed vials (KB-7, active)
        \\Origin: Halvorsen Business Park, Bldg C, loading dock 2
        \\Destination: Memorial Transplant Annex (ETA 3:30 a.m.)
        \\Courier: D. Pruitt, route via the overpass
        \\Seal check: seal re-applied at dock, original seal "found broken, cause unknown"
        \\Temp: hold at 4 C. NOTE: contents may feel warm to the touch. This is normal.
        \\Special handling: DO NOT OPEN IN VEHICLE.
        \\Signed for: [initials illegible]
        ,
    },
    .{
        .id = "lantern.07",
        .set = .lantern,
        .title = "Go / No-Go",
        .author = "Halvorsen executive thread",
        .date = "Day −3",
        .form = .email,
        .rarity = .rare,
        .body =
        \\From: G. Aldridge
        \\To: Safety Review, I. Kessler
        \\Subject: RE: RE: RE: Lantern shipment
        \\Ilse, I understand the concerns. I have also heard the number the board wants on Friday's call, and it is not a number you get by waiting for a safety review.
        \\The Annex trial ships tonight. Dale knows the overpass route. He has done it a hundred times. It is a cooler.
        \\If something goes wrong, we will say we followed protocol. We will have followed protocol, because I am about to write it.
        \\Please stop using the word "leans" in email.
        \\G.
        ,
    },
    .{
        .id = "lantern.08",
        .set = .lantern,
        .title = "The Last Page",
        .author = "Dr. Ilse Kessler, lab notebook, p. 131",
        .date = "Day −1",
        .form = .notebook,
        .rarity = .rare,
        .body =
        \\They are shipping it tonight. I said no in four different ways and then I said it in writing, which is how you know I was scared.
        \\If you are reading this, somebody did not listen.
        \\Burn the plates. Bleach is not enough. I have seen it sit in bleach and think about it. Incense, maybe. Strong soap. Anything that smells like a clean room, because it was cultured in one, and I wonder if it remembers.
        \\It is not a preservation matrix. It is a decision it makes about you.
        \\It is warm. It will always be warm.
        \\I am going to go and stand in the loading dock and watch the van go, and I will hate myself.
        ,
    },

    // --- The Starlite Diner ------------------------------------------------------------------------
    .{
        .id = "starlite.01",
        .set = .starlite,
        .title = "Statement of Rhonda Pickett",
        .author = "Rhonda Pickett, night server, written for the sheriff's office",
        .date = "Day 0, 3:40 a.m.",
        .form = .letter,
        .rarity = .uncommon,
        .body =
        \\He came in at about two. Wet through, though it wasn't raining. Napkins wrapped round his left hand, red coming through them. He had a cooler tucked against his ribs like a baby.
        \\He said "Pie." That was it. Cherry, he said, when I asked, like it was the only word he'd had since the van.
        \\I offered to call someone for the hand. He said his sister was coming. He kept checking his phone. He sat down in table four and the booth got hot. I mean the vinyl. I've sat in that booth. It was HOT.
        \\I told Bud. Bud said the guy looked like a tired trucker. I said tired truckers don't make the coffee machine go quiet.
        ,
    },
    .{
        .id = "starlite.02",
        .set = .starlite,
        .title = "Order Ticket, Table 4",
        .author = "Bud Marchetti, line cook",
        .date = "Day 0, 2:31 a.m.",
        .form = .sticky,
        .rarity = .common,
        .body =
        \\TBL 4 -- 1 cherry pie (slice) -- 1 coffee
        \\86 the cherry after this one. Pie guy at 4 won't eat it. SMELLS it. Holds it up, breathes in, sets it down. Does it again.
        \\Told Rhonda he can have it free if he stops. He didn't stop.
        \\Also the walk-in is humming. Walk-in doesn't hum.
        \\Also I'm hungry, which is dumb, I just ate.
        ,
    },
    .{
        .id = "starlite.03",
        .set = .starlite,
        .title = "Walt Says He Was There",
        .author = "Walt Brzezinski, voicemail to his daughter",
        .date = "Day 1, 7:12 a.m.",
        .form = .radio,
        .rarity = .uncommon,
        .body =
        \\[VOICEMAIL TRANSCRIPT, 1 min 48 s]
        \\Hi honey, it's Dad. Don't worry. Well, worry a little. I'm fine.
        \\I was at the Starlite, like always, third stool, and there was a fellow at four with a cooler. Hand all wrapped. Sweating like he'd run there.
        \\I've had that stool for eleven years. I know every kind of person who comes in at two a.m. This was a new kind.
        \\Then Bud went to talk to him. And then I went out the back with my pie. I left the pie, actually. That is how you know. Anyway. Call me. Lock the door. Don't go to the diner. The pie wasn't even good.
        ,
    },
    .{
        .id = "starlite.04",
        .set = .starlite,
        .title = "Dale's Last Text",
        .author = "Dale Pruitt, to his sister Carol",
        .date = "Day 0, 2:47 a.m.",
        .form = .chat,
        .rarity = .uncommon,
        .body =
        \\Dale: hey Care. van is wrecked. im ok
        \\Dale: cut my hand on the glass. not bad
        \\Dale: at the starlite on route 9. can you come get me
        \\Dale: dont tell mom im at a diner at 2am
        \\Carol: Dale are you ok?? you sound weird
        \\Dale: im really warm. weird right
        \\Dale: its so nice in here
        \\Dale: everybody smells so good
        \\Dale: Care
        \\Dale: Care i think i should go
        ,
    },
    .{
        .id = "starlite.05",
        .set = .starlite,
        .title = "Guest Check #4471",
        .author = "The Starlite Diner",
        .date = "Day 0, 2:14 a.m.",
        .form = .receipt,
        .rarity = .rare,
        .body =
        \\THE STARLITE DINER -- OPEN ALL NIGHT
        \\Server: RHONDA   Table: 4   Guests: 1
        \\ 1  Cherry Pie (slice) ........ 4.25
        \\ 1  Coffee (bottomless) ....... 2.10
        \\ 1  Extra napkins ............. NO CHARGE
        \\ 1  Napkins (more) ............ NO CHARGE
        \\ 1  Napkins (a lot) ........... NO CHARGE
        \\SUBTOTAL 6.35   TAX 0.51   TOTAL 6.86
        \\TIP: ________   PAID: ________
        \\(handwritten) guy at 4 left w/o paying. left blood on the bill. we comped it. he looked sad. hope he's ok.
        \\THANK YOU! COME AGAIN!
        ,
    },
    .{
        .id = "starlite.06",
        .set = .starlite,
        .title = "One Star, From The Bathroom",
        .author = "\"Dale P.\", Local Guide, Level 2",
        .date = "Day 0, 2:58 a.m.",
        .form = .review,
        .rarity = .rare,
        .body =
        \\★☆☆☆☆  Starlite Diner
        \\Pie: great, honestly. Coffee: fine. Bathroom: I am writing this from the bathroom, which I do not recommend.
        \\Soap dispenser empty. Sink warm. The hand towel is red now. That's on me.
        \\Staff very nice, very concerned. Management: please check on your cook, he has been in the walk-in for twenty minutes and I can hear him breathing through the door and I think he is breathing at ME.
        \\One star because I'm not feeling great. Will update.
        ,
    },
    .{
        .id = "starlite.07",
        .set = .starlite,
        .title = "911 Call, 3:06 a.m.",
        .author = "County Emergency Dispatch, call transcript",
        .date = "Day 0, 3:06 a.m.",
        .form = .radio,
        .rarity = .rare,
        .body =
        \\[CALL 0306-114. TRANSCRIPT.]
        \\DISPATCH: 911, what is the address of your emergency?
        \\CALLER: The Starlite on Route 9. A man is biting my cook.
        \\DISPATCH: A man is biting... can you say that again?
        \\CALLER: He's biting Bud. Bud's fine. Bud is not fine. He's up. Bud, sit DOWN.
        \\DISPATCH: Ma'am, is the man who is biting conscious?
        \\CALLER: He's... warm. He's very warm. Is that a thing you can be?
        \\DISPATCH: Ma'am, stay on the line.
        \\CALLER: Oh no. Oh no, Bud, no, not the pie.
        \\[LINE OPEN, 4 min 11 s. NO FURTHER SPEECH.]
        ,
    },

    // --- Ordinary People ---------------------------------------------------------------------------
    .{
        .id = "ordinary.01",
        .set = .ordinary,
        .title = "Re: Biting, and the Bins",
        .author = "Maple Court HOA, Compliance Committee",
        .date = "Day 4",
        .form = .letter,
        .rarity = .common,
        .body =
        \\Dear Resident of 14 Maple Court,
        \\It has come to our attention that you have been (1) biting neighbors, and (2) leaving your bins at the curb after Wednesday collection.
        \\Item (1) is a matter for the Board and will be discussed at the next meeting, if there is a meeting, and if the Board survives. Item (2) is a violation of Covenant 7.3 and carries a fine.
        \\We acknowledge that "the situation" is "ongoing". The fine stands. A reminder: lawn height must not exceed four inches, and the Board's position on the yard is that the yard is also, somehow, the Board's problem.
        \\Warm regards,
        \\Maple Court HOA
        ,
    },
    .{
        .id = "ordinary.02",
        .set = .ordinary,
        .title = "The Fridge Wars, Floor 3",
        .author = "Anonymous, office kitchen",
        .date = "Day 1",
        .form = .sticky,
        .rarity = .common,
        .body =
        \\WHOEVER TOOK MY YOGURT: I KNOW WHO YOU ARE.
        \\--
        \\It was not yogurt. It was a Hunger-Free Wellness Smoothie and it was MINE. I'm not the one who's been "off" this week. Kevin from Accounts is the one who's been "off".
        \\--
        \\Kevin is not in today. Kevin has not been in since Tuesday. Please stop writing notes on Kevin's desk. Kevin bit the printer.
        \\--
        \\Does anyone know why the break room smells like warm bread. Is someone baking. If so I would like some.
        \\--
        \\NOBODY IS BAKING. CLEAN OUT YOUR FRIDGE ITEMS BY FRIDAY. (there are no more Fridays)
        ,
    },
    .{
        .id = "ordinary.03",
        .set = .ordinary,
        .title = "Mr. Biscuits",
        .author = "Lost cat poster, taped to a lamp post on Delancey Street",
        .date = "Day 2",
        .form = .poster,
        .rarity = .uncommon,
        .body =
        \\LOST CAT
        \\MR. BISCUITS
        \\Orange. Fat. Answers to "Biscuits", "Mister", and the sound of a can opening.
        \\Last seen Tuesday near the Pruitts' back fence.
        \\DO NOT LET HIM LICK YOU.
        \\I mean it. He has been acting strange. He found a mouse and then he looked at the mouse for a long time and then he sat very still and purred like a tiny diesel engine. His skin is hot.
        \\If found, call Priya at the number below. Do not pet. Do not feed. Do not make eye contact. He's a good boy.
        \\Reward: Whatever I have left.
        ,
    },
    .{
        .id = "ordinary.04",
        .set = .ordinary,
        .title = "Looking for Someone Who Runs",
        .author = "Profile of \"Jordie, 31\", on a dating app",
        .date = "Day 6",
        .form = .card,
        .rarity = .common,
        .body =
        \\Jordie, 31. 0.4 miles away (that's close).
        \\About me: Former barista. Current survivor. Fluent in sarcasm and in stairwells.
        \\Looking for: someone who runs. FAST. Cardio is the new chemistry.
        \\Dealbreakers: sleepwalkers, anyone who says "I'm just really hungry", people who do not look both ways when entering a pantry.
        \\Green flags: knows a back way out. Has a bike. Can open a can without making noise.
        \\Fun fact: I have been in the same parking structure for nine days and I have a very good relationship with the snack machine.
        \\Swipe right if you've read this far. Swipe left if you're hot. (Literally. I'll know.)
        ,
    },
    .{
        .id = "ordinary.05",
        .set = .ordinary,
        .title = "Group Chat: ROOM 214 FOREVER",
        .author = "Four teenagers, one phone plan",
        .date = "Day 2",
        .form = .chat,
        .rarity = .common,
        .body =
        \\Mika: school is cancelled!!!
        \\Jonah: that's not a W if its because everyone is sick
        \\Mika: its a W for ME. i didnt do the chem lab
        \\Priya: jonah why are you breathing like that on the call
        \\Jonah: im not
        \\Priya: you're making a noise
        \\Jonah: its my allergies
        \\Dev: my neighbor's allergies are also making a noise
        \\Dev: through the wall
        \\Dev: for 3 days
        \\Mika: ok new group name: ROOM 214 FOREVER (stay inside)
        ,
    },
    .{
        .id = "ordinary.06",
        .set = .ordinary,
        .title = "Grandma Is Fine",
        .author = "Voicemail from Grandma Louise",
        .date = "Day 3, 9:41 a.m.",
        .form = .radio,
        .rarity = .common,
        .body =
        \\[VOICEMAIL. TRANSCRIPT. 52 s]
        \\Hello, dear, it's Grandma, I got your seventeen messages. I'm FINE. I'm perfectly fine. Don't come over. I mean it.
        \\The man next door is just very hungry. He's been at the window since Tuesday. I gave him a casserole. He did not want the casserole. He wanted my arm, I think. People are so rude about casseroles lately.
        \\I've locked the screen door. I've put the good china against the back door. If he gets in I'll hit him with the good china.
        \\Eat something. You're too thin. Love you. Don't come over.
        ,
    },
    .{
        .id = "ordinary.07",
        .set = .ordinary,
        .title = "Cancellation, Denied",
        .author = "Fitness Planet, Member Services",
        .date = "Day 5",
        .form = .email,
        .rarity = .common,
        .body =
        \\From: Member Services, Fitness Planet
        \\Subject: RE: Cancel my membership
        \\Dear Mr. Alder,
        \\We have received your request to cancel your membership. Per your agreement, cancellations must be made in person, in writing, with thirty (30) days' notice.
        \\Our records show you attempted to cancel in person on Day 3. The staff member on shift reports that you were "being chased".
        \\As a courtesy, we have frozen your membership for the duration of "the situation". Your monthly fee of $24.99 will continue to be charged.
        \\Your Wellness Journey is important to us!
        ,
    },
    .{
        .id = "ordinary.08",
        .set = .ordinary,
        .title = "My Dad Is Very Warm Now",
        .author = "Ellie, grade 4, science fair abstract",
        .date = "Day 7",
        .form = .letter,
        .rarity = .uncommon,
        .body =
        \\MY DAD IS VERY WARM NOW
        \\by Ellie, age 9
        \\Question: Why is my dad hot?
        \\Hypothesis: He has a fever and needs soup.
        \\Method: I held a thermometer to his head. It went up to the top and then broke. I used the oven thermometer. It said 105. That is for turkey.
        \\Results: He does not want soup. He looks at me a lot. I keep the door locked and slide notes under it. He likes the pictures.
        \\Conclusion: My dad is still my dad but he is a different kind of dad. I will test again tomorrow.
        \\Thank you to Mrs. Ruiz, who is also hot.
        ,
    },
    .{
        .id = "ordinary.09",
        .set = .ordinary,
        .title = "Toast (Cut Short)",
        .author = "Best man's index cards, wedding of Sam and Dee",
        .date = "Day 2, 6:20 p.m.",
        .form = .letter,
        .rarity = .uncommon,
        .body =
        \\[card 1] Hi, I'm Jim, Sam's brother. Dee, you are the best thing that ever happened to my brother, and I say that as someone who has seen the other things.
        \\[card 2] When Sam met Dee he said, "I think I'm going to marry that woman." I said, "You're holding a pizza box." He said, "Same thing."
        \\[card 3] Marriage is about showing up. Through sickness and in health, through...
        \\[card 4] ...um. Is that Uncle Pete? He's been at the buffet for an hour. Uncle Pete, are you ok? PETE.
        \\[card 5] (blank. in pen: to the happy couple. run.)
        ,
    },
    .{
        .id = "ordinary.10",
        .set = .ordinary,
        .title = "Delivery Note: No Tip",
        .author = "Driver's order note, Marco's Pizza",
        .date = "Day 3",
        .form = .sticky,
        .rarity = .common,
        .body =
        \\ORDER 8812, 2 LARGE PEPPERONI
        \\Left pizza on porch. Customer is outside. Customer is also in the yard. Customer does not appear to want pizza.
        \\Customer wants me. Customer is 40 feet from my car and gaining.
        \\NOTE FOR RESTAURANT: do NOT send Danny to this address, Danny is too slow.
        \\NOTE FOR CUSTOMER: pizza is hot, as it is for most of you now.
        \\Tip: $0. Understandable.
        ,
    },
    .{
        .id = "ordinary.11",
        .set = .ordinary,
        .title = "Bake Sale at Saint Anne's",
        .author = "Flyer on the church noticeboard",
        .date = "Day 8",
        .form = .poster,
        .rarity = .common,
        .body =
        \\SAINT ANNE'S ANNUAL BAKE SALE!
        \\THIS SATURDAY after the 10 o'clock
        \\Lemon bars. Banana bread. Snickerdoodles. Mrs. Okonkwo's famous seven-layer, which no one is allowed to ask about.
        \\ALL ARE WELCOME. The doors are open. Come in. Please come in, we do not know why, but they do not come in either.
        \\Father Mike says it is a mercy. Mrs. Okonkwo says it is the candles. Deacon Phil says it is just the draft.
        \\Please bring: a casserole dish, a friend, and a clean pair of shoes.
        \\All proceeds go to the roof, which now has a hole.
        ,
    },
    .{
        .id = "ordinary.12",
        .set = .ordinary,
        .title = "Two Stars for the Apocalypse",
        .author = "\"Homeowner_Gary\", verified resident",
        .date = "Day 10",
        .form = .review,
        .rarity = .uncommon,
        .body =
        \\★★☆☆☆  The End Of The World
        \\Would not recommend. Took forever to arrive and then it all happened on a Tuesday.
        \\Pros: no commute, no HOA emails, a fantastic parking space at the grocery store.
        \\Cons: the grocery store. The neighbors. The noise at night, and also the noise at day. I called to complain and nobody picked up. I called again and a very warm man picked up. We did not connect.
        \\Management response: none.
        \\Would give one star but my lawn has never looked greener. Two stars.
        ,
    },

    // --- Containment ---------------------------------------------------------------------------------
    .{
        .id = "containment.01",
        .set = .containment,
        .title = "Order 14: Curfew",
        .author = "County Emergency Management, Order 14",
        .date = "Day 2",
        .form = .memo,
        .rarity = .uncommon,
        .body =
        \\COUNTY EMERGENCY ORDER 14
        \\Effective 6:00 p.m. tonight, a curfew is in force in every district. Residents shall remain indoors.
        \\This order responds to a "civil disturbance" of unknown origin. It is not a public-health event. It is not an outbreak. Residents who have been bitten should not describe the injury as a "bite".
        \\Residents who feel unusually warm should report to the nearest community hospital. Residents who feel unusually hungry should report to a different one.
        \\Questions may be directed to the information line, which is not currently staffed.
        \\Stay calm. Stay home. Stay quiet.
        ,
    },
    .{
        .id = "containment.02",
        .set = .containment,
        .title = "Radio Log, Checkpoint 9",
        .author = "Sgt. Hollis, 2nd Battalion",
        .date = "Day 2 -- Day 4",
        .form = .radio,
        .rarity = .uncommon,
        .body =
        \\0412: Checkpoint set. Eight vehicles queued.
        \\0431: Man in 3rd vehicle says he "isn't feeling great". Is warm. Pulled aside.
        \\0447: He bit Pvt Haas. Haas says it is "fine".
        \\0509: Haas is warm.
        \\0612: Request guidance from command.
        \\0620: Command says: "Maintain the line."
        \\0701: Maintaining the line. There are now more of them than there are of us.
        \\0702: Requesting guidance.
        \\0713: Guidance received: "Do not use the word 'zombie' on the net."
        \\0714: Copy. Please advise a better word.
        ,
    },
    .{
        .id = "containment.03",
        .set = .containment,
        .title = "Form Q-12: Checkpoint Screening",
        .author = "Quarantine checkpoint, Route 9 North",
        .date = "Day 3",
        .form = .memo,
        .rarity = .uncommon,
        .body =
        \\QUARANTINE SCREENING FORM Q-12 (complete in block capitals)
        \\1. Name: ________
        \\2. Have you been bitten, scratched, or "licked"? [ ] Y [ ] N [ ] DEFINE "LICKED"
        \\3. Do you currently feel unusually warm? [ ] Y [ ] N   (If yes, do not tick N.)
        \\4. Have you eaten in the last 6 hours? [ ] Y [ ] N [ ] WHO ARE YOU PEOPLE
        \\5. Do you have any desire to bite the examiner? [ ] Y [ ] N [ ] SLIGHTLY
        \\Examiner's note: Subject ticked every box. Subject then ate the pen. Subject cleared for entry.
        ,
    },
    .{
        .id = "containment.04",
        .set = .containment,
        .title = "Broadcast Script, Marked Up",
        .author = "National Emergency Broadcast, final script (annotated)",
        .date = "Day 3, 6:00 a.m.",
        .form = .memo,
        .rarity = .rare,
        .body =
        \\EMERGENCY BROADCAST. ALL STATIONS.
        \\Containment has failed in every district. If you can read this, it is already in your city.
        \\Stay off the main roads. Do not trust anyone who is calm.
        \\The infected do not tire. They follow heat, and sound, and [handwritten: and what? "and hunger"? CUT "hunger"] [handwritten: ...and they do not stop.]
        \\[handwritten margin] Do not say "zombie". Do not say "contagious". Do not say "Halvorsen". Do NOT say "Halvorsen". Legal says to say "an industrial incident".
        \\[handwritten margin] Do we tell them about the churches? Doesn't matter. Nobody will read this far.
        \\[handwritten, bottom] Read it flat. Read it slow. If you cry, we go to the next script.
        ,
    },
    .{
        .id = "containment.05",
        .set = .containment,
        .title = "Letter Home, Unsent",
        .author = "Pvt. Anna Voss, to her mother",
        .date = "Day 4",
        .form = .letter,
        .rarity = .rare,
        .body =
        \\Mom,
        \\They told us this would be a short rotation. I have my boots on. I have all my fingers. I am eating my crackers. I want you to know I am okay.
        \\I am not allowed to say where I am. I am at a bridge. I will say the bridge is very tall and very wet and very full of people who aren't going anywhere.
        \\The thing they warned us about is real, and it's not what I thought. They aren't angry. They look so sad, Mom. They look at you like you're the last warm room in the world.
        \\Don't believe the broadcast. Go to the church. The big one on Maple. Take Grandpa's rosary. Take the cat.
        \\Love, Anna
        ,
    },
    .{
        .id = "containment.06",
        .set = .containment,
        .title = "Field Memo: Thermal Signature",
        .author = "Capt. R. Lindqvist, Field Sciences Attaché",
        .date = "Day 4",
        .form = .memo,
        .rarity = .rare,
        .body =
        \\SUBJECT: THERMAL SIGNATURE OF INFECTED PERSONNEL
        \\On thermal, the infected read white-hot: roughly 41 degrees core, with no variance between torso and hands. That is a person who is burning and not dying.
        \\Behaviorally: infected do not track by sight, or by sound alone. They track heat. A warm body in a cold room is a lighthouse. A blanket soaked in cold water works. So does standing in a stream.
        \\Recommended: cold shelter, wet cloth, stillness. Avoid running (raises core temperature).
        \\Note: We are, from their perspective, lanterns. I do not know who named the program. I would like to know.
        ,
    },
    .{
        .id = "containment.07",
        .set = .containment,
        .title = "Order to Fall Back",
        .author = "Task Force Command, secure net, transcript",
        .date = "Day 5, 4:20 a.m.",
        .form = .radio,
        .rarity = .rare,
        .body =
        \\[TRANSCRIPT. ALL UNITS. PRIORITY.]
        \\All units, all units, this is Command.
        \\The cordon is no longer viable. I say again, the cordon is no longer viable.
        \\All units fall back to Rally Point Two. Do not engage unless engaged. Do not wait for stragglers. Do not wait for orders.
        \\Leave the vehicles. They hear the engines. Leave the radios on, for them to hear.
        \\God help us, we tried. Command out.
        \\[SIGNAL LOST. 4:23 a.m.]
        ,
    },

    // --- The Survey (Humans) ---------------------------------------------------------------------
    .{
        .id = "survey.01",
        .set = .survey,
        .title = "Grid 4: To Whoever Comes After",
        .author = "Marguerite, Survey Lead, Grid 4",
        .date = "Day 7",
        .form = .letter,
        .rarity = .common,
        .body =
        \\To whoever finds this map,
        \\We are the County Survey. Retirees, surveyors, scout leaders, one dentist. We are not soldiers. We have grease pencils and an unreasonable belief in paper.
        \\The roads are lines. The lines are lies. What matters is where the water is, where the doors lock, and where it is quiet.
        \\We have marked this map the way we always marked maps: so a stranger could read it. If you are reading it, you are the stranger. Welcome. Please do not write on the laminated ones.
        \\Marguerite, Survey Lead, Grid 4
        ,
    },
    .{
        .id = "survey.02",
        .set = .survey,
        .title = "Legend: What The Marks Mean",
        .author = "County Survey, Grid 4 field legend",
        .date = "Day 8",
        .form = .memo,
        .rarity = .common,
        .body =
        \\GREASE PENCIL LEGEND (Grid 4)
        \\ O  circle: safe to sleep one night
        \\ X  cross: gone. do not enter
        \\ +  plus: water, running or stored
        \\ ~  wave: a dead zone where they gather
        \\ ^  caret: high ground. watch from here
        \\ !! two marks: do not go in at night
        \\ $  a dollar sign: food (please don't ask us why we picked it)
        \\ ?  a question mark: Dot's still not sure. Ask Dot.
        \\Mark small. Mark often. Never mark a place you cannot get back from.
        ,
    },
    .{
        .id = "survey.03",
        .set = .survey,
        .title = "They See Warm, So Be Cold",
        .author = "Scoutmaster Ortega, Troop 212 lesson plan",
        .date = "Day 9",
        .form = .notebook,
        .rarity = .uncommon,
        .body =
        \\LESSON: HOW THEY SEE.
        \\1. They don't see like us. They see warm. A person is a bonfire. A wall is a shadow. A cold stream is nothing.
        \\2. So we are bonfires. How do we stop being bonfires? We get cold.
        \\3. Wet blanket. Stone wall at your back. Stay in the shade. A sleeping bag is a BAD idea (you are in a warm cocoon with only a zipper between you and them).
        \\4. Do NOT run. Running makes you hotter. Walk. Breathe slow. Count by twos.
        \\Kids, repeat after me: "They see warm, so be cold."
        \\(Marcus asked if that means we can't have campfires. Yes, Marcus.)
        ,
    },
    .{
        .id = "survey.04",
        .set = .survey,
        .title = "Cache Log, Grid 4",
        .author = "County Survey, supply log",
        .date = "Day 10",
        .form = .radio,
        .rarity = .uncommon,
        .body =
        \\CACHE 1 -- Maple & 3rd. Under the porch. 6 cans, 1 bandage roll, 1 flashlight (dead).
        \\CACHE 2 -- Library basement, behind the "Local History". Water, 12 liters. Do not drink the blue one.
        \\CACHE 3 -- Old fire station, hose room. Hardtack. A knife, which is Dot's.
        \\CACHE 4 -- Saint Anne's, behind the organ. Candles, matches, canned peaches.
        \\Take one thing. Leave one thing. Mark what you took. If you cannot leave a thing, leave a note.
        \\(Someone left a note in Cache 2 that said "thanks, nice peaches". There were no peaches in Cache 2.)
        ,
    },
    .{
        .id = "survey.05",
        .set = .survey,
        .title = "Sanctuary Rules",
        .author = "County Survey, posted at Saint Anne's",
        .date = "Day 11",
        .form = .poster,
        .rarity = .uncommon,
        .body =
        \\SANCTUARY RULES (Hospitals / Schools / Churches)
        \\1. They don't come in. We don't know why. Don't make a thing of it.
        \\2. You may rest. You may NOT fight on the ground. Don't bring a fight to a quiet place.
        \\3. No one who has been bitten sleeps inside until they are cleared. Marguerite decides. You can argue with her. You will lose.
        \\4. Leave the doors open. Keep the lamps low. Wash your hands (the soap seems to matter).
        \\5. Do not stay forever. The quiet is not a home.
        \\6. If you are reading this and the lights are on: hello. Stay a while. We saved you the good chair.
        ,
    },
    .{
        .id = "survey.06",
        .set = .survey,
        .title = "The Incense Argument",
        .author = "Survey net, Grid 4 channel",
        .date = "Day 12",
        .form = .chat,
        .rarity = .rare,
        .body =
        \\Dot: its the incense. Every sanctuary smells like church
        \\Hal: the hospital doesnt smell like church
        \\Dot: it smells like a church for sick people
        \\Hal: its the disinfectant. Bleach. Alcohol. Something in the stuff that cleans
        \\Dot: the school has neither
        \\Hal: the school has floor wax
        \\Dot: THE SCHOOL HAS FLOOR WAX
        \\Marguerite: Both of you stop. We'll test it. Dot, bring incense. Hal, bring bleach. Bring a volunteer who's feeling brave.
        \\Hal: not it
        \\Dot: not it
        \\Marguerite: Both of you are it.
        ,
    },
    .{
        .id = "survey.07",
        .set = .survey,
        .title = "A Note on Maps",
        .author = "Marguerite, Survey Lead, Grid 4",
        .date = "Day 13",
        .form = .letter,
        .rarity = .rare,
        .body =
        \\A map is a promise. When I marked this road as safe I was promising a stranger I did not know that it was.
        \\I have broken that promise four times. I know the names of two of the strangers.
        \\So I mark smaller now. A circle is not "safe". A circle is "I slept here and I woke up".
        \\Forty years I surveyed property lines for people who wanted to know where their land ended. I thought lines were the point. Turns out they never were. Turns out the point is the person who comes after and reads what you left.
        \\Be that person. Be the one who leaves a mark.
        \\M.
        ,
    },
    .{
        .id = "survey.08",
        .set = .survey,
        .title = "Last Entry, Grid 4",
        .author = "Marguerite, Survey Lead, Grid 4",
        .date = "Day 21",
        .form = .notebook,
        .rarity = .rare,
        .body =
        \\Grid 4 is empty. I'm the last one in the library. Dot went north with the good map. Hal went to look at the school and did not come back, which is also an entry.
        \\I'm leaving this notebook on the table with the maps. If it's you: read the marks. They're good. I checked them twice.
        \\I'll tell you one thing I know for sure. It's not the incense. It's not the bleach. I think it's the quiet. I think the places that care about being quiet are the ones that hold. I don't know why. I never will.
        \\Take the peaches. I left you the peaches.
        \\Marguerite, Survey Lead, Grid 4
        ,
    },

    // --- The Hunger (Zombies) --------------------------------------------------------------------------
    .{
        .id = "hunger.01",
        .set = .hunger,
        .title = "warm",
        .author = "a mother, remembered",
        .date = "not counted",
        .form = .card,
        .rarity = .rare,
        .body =
        \\there is a small warm thing i am supposed to find.
        \\i do not have its name. i have its weight. i have the way it fit under my chin. i have a smell, like bread and soap and something sweet gone a little sour. i know it laughed. i know the laugh was the best sound.
        \\i walk past a hundred warm things. none of them are it.
        \\i keep walking.
        \\somebody calls the name sometimes, in the dark, from a window. it is a good name. it sounds like warmth.
        ,
    },
    .{
        .id = "hunger.02",
        .set = .hunger,
        .title = "seven across",
        .author = "someone who keeps trying",
        .date = "not counted",
        .form = .card,
        .rarity = .common,
        .body =
        \\i have a crossword. it is the sunday one. the corner is gone but the clues are all right here.
        \\seven across. six letters. "to consume."
        \\eating. no that's six. that's six. what is wrong with it.
        \\i have been standing at the newsstand for a long time. the pencil is in my hand. i do not know whose hand.
        \\twelve down. "fever's partner." chills. chills. no that is not it. the hunger. THE HUNGER. hunger is six.
        \\seven across. hunger.
        \\i got one. i am so proud.
        ,
    },
    .{
        .id = "hunger.03",
        .set = .hunger,
        .title = "the street, smelled",
        .author = "one of the turned",
        .date = "not counted",
        .form = .card,
        .rarity = .common,
        .body =
        \\the street has a map and it is all smell.
        \\there is a bakery, cold now, but the walls remember. there is a bus stop that smells like a hundred people leaving.
        \\there is a house with a light in it. the light is warm. behind the light, something is breathing. i can taste the breathing from here.
        \\i do not decide. the street decides. i am a leaf on it.
        \\i stand outside the house for four hours. they do not know. the door is a shape of cold. i wait for the cold to open.
        ,
    },
    .{
        .id = "hunger.04",
        .set = .hunger,
        .title = "good dog",
        .author = "a man in a yard",
        .date = "not counted",
        .form = .card,
        .rarity = .uncommon,
        .body =
        \\there is a dog in the yard. it is not mine. i think it used to be mine.
        \\it sits at the fence and it is not afraid. it should be afraid. i am warm and wrong. it just sits and looks at me with its whole face.
        \\i do not want to eat the dog. that is the strange part. it is warm and it smells like a good thing, and i do not want to.
        \\i put my hand on the fence. it puts its nose on my hand. it is so wet and so cold, that nose.
        \\i stay for a long time. the hunger waits. it waits for me. it is very patient. it has all the time.
        ,
    },
    .{
        .id = "hunger.05",
        .set = .hunger,
        .title = "the quiet doors",
        .author = "one of the turned, at a church",
        .date = "not counted",
        .form = .card,
        .rarity = .uncommon,
        .body =
        \\there is a door i cannot go through.
        \\it is not locked. it is open. the light inside is low and gold. there are voices, singing, small. there are so many warm things in there. so many.
        \\the air at the door tastes like nothing. like a slap. like the smell of a clean room, a long time ago, in a building with white walls.
        \\i stand at the edge of it and the hunger goes quiet.
        \\i do not think that is a kindness. i think it is a wall.
        \\i stay anyway. there is a candle. there is a smell of smoke and sweetness. i sit in the road and listen to them sing and for a while i am almost a person.
        ,
    },
    .{
        .id = "hunger.06",
        .set = .hunger,
        .title = "the 8:14",
        .author = "a commuter",
        .date = "not counted",
        .form = .card,
        .rarity = .common,
        .body =
        \\i am at the bus stop. it is the 8:14.
        \\it is not coming. i know it is not coming. i have known for a long while. i am still at the bus stop.
        \\i have a briefcase. there is nothing in it. i hold it anyway. it is very important. i have a meeting.
        \\a man in a hat is also at the bus stop. he is also waiting. we do not look at each other. we are two professionals.
        \\the 8:14 does not come. i do not leave. someone has to be here when it does.
        ,
    },
    .{
        .id = "hunger.07",
        .set = .hunger,
        .title = "quiet in here",
        .author = "the fever",
        .date = "not counted",
        .form = .card,
        .rarity = .rare,
        .body =
        \\it is quiet in here now.
        \\before, there was a lot of noise. rent. a phone. a sister's voice. a list. a list of things that i did wrong, that i could fix, that i should have done by now.
        \\the fever took the list. it took it gently.
        \\i am warm. i am so warm. i have never been this warm. there is only one question left and it is so simple and so kind: are you hungry. yes. then eat.
        \\i would like to be afraid. i remember that being a thing. i remember that i should be.
        \\but it is so quiet in here.
        ,
    },
    .{
        .id = "hunger.08",
        .set = .hunger,
        .title = "hello my name is",
        .author = "a name tag",
        .date = "not counted",
        .form = .card,
        .rarity = .uncommon,
        .body =
        \\there is a sticker on my chest. it says HELLO MY NAME IS and then a name in blue marker.
        \\the name is smeared. i have been rubbing it with my thumb for days. i can read a D. maybe an R. maybe it was a short name. i can feel the shape of how it was said.
        \\someone said it to me once, loudly, from across a room. they were happy to see me.
        \\i would like to be said like that again.
        \\a man in a doorway looks at me and says "hey, buddy". i hold on to it. it is not my name. it is close.
        ,
    },

    // --- Patient Zero ------------------------------------------------------------------------------------
    .{
        .id = "zero.01",
        .set = .zero,
        .title = "Leave of Absence",
        .author = "Halvorsen Human Resources",
        .date = "Day −21",
        .form = .memo,
        .rarity = .legendary,
        .body =
        \\HALVORSEN BIOLOGICS -- HUMAN RESOURCES
        \\EMPLOYEE: Reyes, Tomas (Lab Technician II, Translational Group)
        \\ACTION: Medical leave, effective immediately, three (3) weeks, paid.
        \\Employee was escorted from the premises at 4:40 p.m. by Security. Employee was "calm". Employee has asked for the leave to be recorded as "personal", not "medical". This request is approved.
        \\Do not contact the employee. Do not discuss the employee. Do not send flowers.
        \\Badge deactivated. Locker emptied (contents to Facilities, see attached; note: a half-eaten sandwich, a lunchbox that was warm).
        \\Approved: G. Aldridge
        ,
    },
    .{
        .id = "zero.02",
        .set = .zero,
        .title = "Incident Report 0-0 (Unfiled)",
        .author = "Halvorsen Safety Office, incident report",
        .date = "Day −24",
        .form = .memo,
        .rarity = .legendary,
        .body =
        \\INCIDENT 0-0. FILED BY: I. Kessler. STATUS: DO NOT FILE WITH EH&S.
        \\At 11:12 a.m., a technician handled KB-7 Plate 31 with a torn nitrile glove. Skin contact: palm, approx. 2 cm. Washed within 8 minutes. No symptoms at time of report.
        \\Marginal note, G. Aldridge: "No symptoms means no incident. This is an internal matter. Do not log with Environmental Health and Safety. If it gets out, we lose the licence, the trial, and the company."
        \\Marginal note, I. Kessler: "He's running a temperature of 38.6. I will log it myself."
        \\Marginal note, G. Aldridge: "You will not."
        \\[The report was never filed.]
        ,
    },
    .{
        .id = "zero.03",
        .set = .zero,
        .title = "Voicemail From Tomas",
        .author = "Tomas Reyes, to Dr. Kessler",
        .date = "Day −10, 3:12 a.m.",
        .form = .radio,
        .rarity = .legendary,
        .body =
        \\[VOICEMAIL. TRANSCRIPT. 1 min 06 s.]
        \\Hi, Dr. Kessler. It's Tomas. I know it's late.
        \\I'm okay. I'm just... warm. I haven't been cold in two weeks. I took my temperature and I took it again.
        \\I can't stop smelling the building. Not the labs. The people in it. I could tell you who's on shift. I could tell you where. It's like a map. It's so... I'm sorry. I'm sorry. I'm not coming in.
        \\I haven't eaten in days. I'm not hungry. I'm... I need to stop calling it that.
        \\Please don't let them... don't let them put me in the quiet wing.
        \\I'll be okay. I'm just really warm.
        ,
    },
    .{
        .id = "zero.04",
        .set = .zero,
        .title = "To My Mother",
        .author = "Tomas Reyes, to Mamá",
        .date = "Day −8",
        .form = .chat,
        .rarity = .legendary,
        .body =
        \\Tomas: Mamá, I'm okay
        \\Mamá: Where are you? The people from your work came to the house
        \\Tomas: What people
        \\Mamá: A man in a suit. He said you were on a leave. He wanted your things.
        \\Tomas: Don't give them anything
        \\Mamá: Mijo, are you eating?
        \\Tomas: yes
        \\Tomas: no
        \\Tomas: Mamá, I love you. Lock the door tonight. And the day after.
        \\Mamá: Tomas?
        \\[Read 3:02 a.m. No reply.]
        ,
    },
    .{
        .id = "zero.05",
        .set = .zero,
        .title = "Sublevel 2",
        .author = "G. Aldridge, to Security Operations",
        .date = "Day −2",
        .form = .memo,
        .rarity = .legendary,
        .body =
        \\CONFIDENTIAL. SECURITY OPERATIONS ONLY.
        \\Subject T.R. is stable in the Quiet Wing, Sublevel 2. He does not appear in any ledger. He does not appear in payroll. He is on leave.
        \\Should the Annex shipment incur an incident, the cooler's lot number should be listed as the first exposure. The courier will be the story. The courier has a cut hand and an unlucky name. We have a van and a route and a believable timeline.
        \\Do not, under any circumstances, let Dr. Kessler see Sublevel 2 again.
        \\[handwritten, different pen] The Sublevel 2 door was found open this morning. The lock was not forced. It was opened from the inside, which is not possible. Please advise.
        ,
    },

    // --- Along the Road (landmark notes) ----------------------------------------------------------------
    .{
        .id = "road.01",
        .set = .road,
        .title = "Aisle 6",
        .author = "Nadia, pharmacist, shelf note",
        .date = "Day 6",
        .form = .sticky,
        .rarity = .uncommon,
        .place = .pharmacy,
        .body =
        \\COUGH SYRUP: limit 2 per customer (I don't care anymore, take four).
        \\Aisle 6: antiseptic, the blue bottle. TAKE IT. Don't ask why.
        \\Something odd. When I mop the floor with the blue stuff, they won't come past the door. When I mop with the green stuff, they do. I tried it four times. The fourth was an accident, and I'd like to thank the door.
        \\I have a theory and I'm not going to write it down because it sounds stupid.
        \\It's the smell. That's the theory. It's definitely the smell.
        \\-- N.
        ,
    },
    .{
        .id = "road.02",
        .set = .road,
        .title = "Pump 3 Sign",
        .author = "Hand-lettered sign, Route 9 Gas & Go",
        .date = "Day 9",
        .form = .poster,
        .rarity = .common,
        .place = .fuel,
        .body =
        \\GAS: NO
        \\SNACKS: SOME
        \\COFFEE: YES (it is bad)
        \\RESTROOM: NO (a person lives in it)
        \\ZOMBIES: ASK INSIDE (don't)
        \\Sorry we are out of the good jerky. We are out of the bad jerky. We are also out of the jerky.
        \\Cash only. Cash is no good. Take what you want. Leave a note.
        \\THANK YOU FOR STOPPING AT GAS & GO!
        ,
    },
    .{
        .id = "road.03",
        .set = .road,
        .title = "Everything Must Go (We Mean It)",
        .author = "Hardware store window sign",
        .date = "Day 8",
        .form = .poster,
        .rarity = .common,
        .place = .hardware,
        .body =
        \\EVERYTHING MUST GO
        \\(WE MEAN IT)
        \\50% OFF ALL HAMMERS.  80% OFF ALL AXES.  100% OFF CROWBARS.
        \\We used to be a "Going Out Of Business" sale. We have been a "Going Out Of Business" sale for eleven years. This time it is real. The owner went out of business with a very long stick.
        \\NO REFUNDS. NO RETURNS. NO QUESTIONS. NO, THE GENERATOR IS NOT FOR SALE. YES, THE GENERATOR IS FOR SALE.
        \\Please keep the receipts. For the memories.
        ,
    },
    .{
        .id = "road.04",
        .set = .road,
        .title = "Produce, Closing Down",
        .author = "Hector, produce manager, shelf-edge sign",
        .date = "Day 7",
        .form = .sticky,
        .rarity = .common,
        .place = .grocery,
        .body =
        \\AISLE 9: DO NOT.
        \\Bananas: 0.00 (they were never going to make it)
        \\Artichokes: 0.00 (I do not know why we have this many artichokes)
        \\Bag of ice: still 4.99, because the freezer is still running and I'm a man of principle
        \\If you're reading this, take the artichokes. Please. There are nine hundred artichokes. I have been eating them for a week. I am becoming an artichoke.
        \\-- H.
        ,
    },
    .{
        .id = "road.05",
        .set = .road,
        .title = "Lifetime Guarantee",
        .author = "Trailhead Outfitters, warranty card",
        .date = "Day 5",
        .form = .card,
        .rarity = .uncommon,
        .place = .outfitter,
        .body =
        \\TRAILHEAD OUTFITTERS -- LIFETIME GUARANTEE
        \\If this product fails for any reason during your lifetime, bring it back and we will replace it free.
        \\(handwritten) UPDATE: "lifetime" now means "until Tuesday".
        \\Return Form 7B: reason for return.
        \\ [ ] Zipper broke   [ ] Seam split   [X] Neighbors don't work
        \\Tent was fine. Tent was great, honestly, 4-person, held up in the wind. The neighbors were the problem.
        \\Exchange for: a bigger tent. A tent with a door that locks. A tent made of walls.
        ,
    },
};
