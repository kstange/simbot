# =============================================================================
#  SimBot Configuration File
# =============================================================================

# The config.default.pl file should be copied to config.pl when you first
# set up the bot.  You should edit config.pl to contain the desired
# configuration settings for your bot.  You should not need to edit simbot.pl
# unless the path to perl is not correct for your system.

# This file is called config.default.pl so that you can download and dump a
# new version with a clean config template into the same directory without
# overwriting your existing configuration, while still giving you the chance
# to see if someone stuck anything new and/or useful in here.

# This is the path to the rules database we will use.  In most cases the
# default, which is to put a rules.db file in the current directory, is fine.
$rulefile = "./rules.db";

# This is an array of servers you want the bot to try.  It will select a
# server randomly from this list each time it attempts to connect.  Add
# servers on their own line, in quotes, followed by a comma to keep the
# list tidy. Make sure the servers you choose allow bots.  Don't pick
# "random server" hosts, such as irc.undernet.org.  There's a chance that
# these will put your bot where it is not welcome, and you don't want it
# or you being killed by IRC ops because it's breaking server rules.
@server = (
	   "mesa.az.us.undernet.org",
	   "washington.dc.us.undernet.org",
	   "princeton.nj.us.undernet.org",
	   "sanjose.ca.us.undernet.org",
	   "miami.fl.us.undernet.org",
	   "panamacity.pa.us.undernet.org",
	   "Helsinki.FI.EU.Undernet.org",
	   "Zagreb.Hr.EU.UnderNet.org",
	   );

# This is the channel that you want the bot to join when it connects to
# one of the specified servers.
$channel = "#MyChannel";

# This is the default nickname that the bot should use when it connects
# to the server.  If the nickname is not available the bot will rotate
# the letters in the nickname to the right, (so "MyBot" becomes "tMybo")
# until it finds a nickname that is not in use.
$nickname = "MyBot";

# The bot will respond to this tag if it is specified in addition to the
# default nickname and its current nickname.
$alttag   = "MB";

# The username below will be passed to the IRC network as the bot's
# IRC name.  If a password is provided, the bot will attempt to
# log into channel services with the username and password.  Currently
# only the Undernet Channel Service is supported.
$username = "mybot";
$password = "";

# This is the percent change of the bot appending an extra sentence to
# the end of its reply.  10% tends to work decently.  Going too close to
# 100% will annoy users waiting several minutes for replies.
$exsenpct = "10";

# The bot will use one of these greetings when a user greets it with the
# word "Hi."  The user's nickname is appended to the end of the message.
@greeting = (
	     "Hi there, ",
	     "How's it going, ",
	     "Good to see you, ",
	     "Hello, ",
	     "What's up, ",
	     );

# This is the list words here that should not be allowed in the database.
# At the moment, this will block entire lines containing matches, because
# I haven't worked out a way to avoid creating potential dead end words
# otherwise.  This set is built from words that I've seen and wanted to
# block, but there are certainly more that could go here.  These are in
# the form of single-word precompiled regular expressions.  You can add
# whole words in quotes to this list as well.
@chat_ignore = (
		qr/(ph|f)u+ck/,
		qr/shi+t/,
		qr/^dick/,
		qr/^clit/,
		qr/^cock/,
		qr/^penis/,
		qr/^penes/,
		qr/^tits/,
		qr/goatse/,
		qr/tubgirl/,
		qr/^jackoff/,
		qr/^queer/,
		qr/^gay/,
		qr/^wank/,
		qr/^hump$/,
		qr/^asshole$/,
		qr/^http\/\//,
		qr/^ftp\/\//,
		qr/^cum$/,
		qr/^sodom/,
		qr/^titf/,
		qr/nigg/,
		qr/niqq/,
		qr/(ph|f)ux/,
		qr/ghe[iy]/,
		qr/^(ph|f)ag/,
		qr/^nigs?$/,
		);

# End of Config
1;
