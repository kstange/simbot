#!/usr/bin/perl

# SimBot
#
# Copyright (C) 2002-03, Kevin M Stange <kevin@simguy.net>
#
# This program is free software; you can redistribute it and/or modify
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# NOTE: You should not edit this file other than the path to perl at the top
#       unless you know what you are doing.  Submit bugfixes back to:
#       http://sf.net/projects/simbot

# Hi, my name is:
package SimBot;

# Load the configuration file in.  We're not going to try to deal with what
# happens if this fails.  If you have no configuration, you should get one
# before you try to do anything.
require "./config.pl";

# Check some config options or bail out!
die("Your config.pl is lacking an IRC server to connect to!") unless @server;
die("Your config.pl is lacking a channel to join!") unless $channel;
die("Your config.pl is lacking a valid default nickname!") unless (length($nickname) >= 2);
die("Your config.pl has an extra sentence % >= 100%!") unless ($exsenpct < 100);
die("Your config.pl has no rulefile to load!") unless $rulefile;

if($gender eq 'M') {
    $hisher = 'his';
} elsif ($gender eq 'F') {
    $hisher = 'her';
} else {
    $hisher = 'its';
}

# ****************************************
# *********** Random Variables ***********
# ****************************************

# Force debug on with this:
# 0 is silent, 1 shows errors, 2 shows warnings, 3 shows lots of fun things,
# 4 shows everything you never wanted to see.
$verbose = 3;

# Software Name
$project = "SimBot";
# Software Version
$version = "6.0 alpha";

# Channel information will be written to these files.
# These actually don't do anything at all.
#$topicfile  = "../Web Site Stuff/Web Server/Files/$project-topic";
#$usersfile  = "../Web Site Stuff/Web Server/Files/$project-users";
#$ucountfile = "../Web Site Stuff/Web Server/Files/$project-ucount";

# ****************************************
# ************ Start of Script ***********
# ****************************************

%event_plugin_call = (
		      "stats",   "print_stats",
		      "help",    "print_help",
		      "list",    "print_list",
		      );

%plugin_type = (
		"stats",   "INT",
		"help",    "INT",
		"list",    "INT",
		);

%plugin_desc = (
		"stats",   "Shows useless stats about the database.",
		"help",    "Shows this message.",
		);		

# We'll need this perl module to be able to do anything meaningful.
$kernel = new POE::Kernel;
use POE;
use POE::Component::IRC;

opendir(DIR, "./plugins");
foreach(readdir(DIR)) {
    if($_ =~ /.*\.pl$/) {
	if(eval { require "./plugins/$_"; }) {
	    debug(3, "$_ plugin loaded successfully.\n");
	} else {
	    debug(2, "$_ plugin did not load due to errors.\n");
	}
    }
}
closedir(DIR);

# We want to catch signals to make sure we clean up and save if the
# system wants to kill us.
$SIG{'TERM'} = 'SimBot::cleanup';
$SIG{'INT'}  = 'SimBot::cleanup';
$SIG{'HUP'}  = 'SimBot::cleanup';
$SIG{'USR1'} = 'SimBot::restart';
$SIG{'USR2'} = 'SimBot::reload';

# Load the massive table of rules simbot will need.
&load;

# Set line counter to zero.  We'll save when this hits a threshold,
# or if the time is right.
$items = 0;

# We are not terminating in the default case.  Duh.
$terminating = 0;

# Create a new IRC connection.
POE::Component::IRC->new('bot');

# Add the handlers for different IRC events we want to know about.
POE::Session->new
  ( _start           => \&make_connection,
    irc_001          => \&init_bot,         # connected
    irc_public       => \&process_public,
    irc_msg          => \&process_priv,
    irc_notice       => \&process_notice,
    irc_ctcp_action  => \&process_action,
    irc_ctcp_version => \&process_version,
    irc_ctcp_time    => \&process_time,
    irc_ctcp_finger  => \&process_finger,
    irc_ctcp_ping    => \&process_ping,
    irc_disconnected => \&reconnect,
    irc_socketerr    => \&reconnect,
    irc_433          => \&pick_new_nick,    # nickname in use
    irc_kick         => \&check_kick,
    irc_invite       => \&check_invite,
    irc_471          => \&request_invite,   # channel is at limit
    irc_473          => \&request_invite,   # channel invite only
    irc_474          => \&request_invite,   # banned from channel
    irc_475          => \&request_invite,   # bad channel key
    irc_ping         => \&ping_event,       # do some things on a regular basis
    irc_303          => \&check_nickname,   # check ison reply
  );

# ****************************************
# ********* Start of Subroutines *********
# ****************************************

# ########### GENERAL PURPOSE ############

# DEBUG: Print out messages with the desired verbosity.
sub debug {
    my @errors = ("",
		  "ERROR: ",
		  "WARNING: ",
		  "",
		  "",
		  );
    if ($_[0] <= $verbose) {
	print STDERR $errors[$_[0]] . $_[1];
    }
}

# PICK: Pick a random item from an array.
sub pick() {
    return @_[int(rand()*@_)];
}

# HOSTMASK: Generates a 'type 3' hostmask from a nick!user@host address
sub hostmask() {
    my ($nick, $user, $host) = split(/[@!]/, $_);
    if ($host =~ /(\d{1,3}\.){3}\d{1,3}/) {
	$host =~ s/(\.\d{1,3}){2}$/\.\*/;
    } else {
	$host =~ /^(.*)(\.\w*?\.[\w\.]{3,5})$/;
	$host = "*$2";
    }
    $user =~ s/^~?/*/;
    return "*!$user\@$host";
}

# TIMEAGO: Returns a string of how long ago something happened
sub timeago {
    my ($seconds, $minutes, $hours, $days, $weeks, $years);
    $seconds = time - $_[0];
    if($seconds > 60) {
        $minutes = int $seconds / 60;
        $seconds %= 60;
        if($minutes > 60) {
            $hours = int $minutes / 60;
            $minutes %= 60;
            if($hours > 24) {
                $days = int $hours / 24;
                $hours %= 24;
                if($days > 365) {
                    $years = int $days/365;
                    $days %= 365;
                }
            }
        }
    }
    
    my $reply;
    $reply = "$years year" . (($years == 1) ? ' ' : 's ') if $years;
    $reply .= "$days day" . (($days == 1) ? ' ' : 's ') if $days;
    $reply .= "$hours hour" . (($hours == 1) ? ' ' : 's ') if $hours;
    $reply .= "$minutes minute" . (($minutes == 1) ? ' ' : 's ') if $minutes;
    $reply .= "$seconds second" . (($seconds == 1) ? ' ' : 's ') if $seconds;
    if($reply) {
        $reply .= 'ago';
    } else {
        $reply = 'very recently';
    }
    return $reply;
}

# RESTART: Quits and restarts the script.  This should be done
#          after the script is updated.
sub restart {
    &debug(3, "Received restart call...\n");
    &save;
    foreach(keys(%event_plugin_unload)) {
	&plugin_callback($_, $event_plugin_unload{$_});
    }
    &debug(3, "Disconnecting from IRC...\n");
    &quit("Restarting, brb...");
    &debug(3, "Restarting script...\n");
    exec "./simbot.pl";
}

# CLEANUP: Terminates the script immediately after saving.
sub cleanup {
    &debug(3, "Received cleanup call...\n");
    &save;
    foreach(keys(%event_plugin_unload)) {
	&plugin_callback($_, $event_plugin_unload{$_});
    }
    &debug(3, "Disconnecting from IRC...\n");
    &quit("Bye everyone!");
    &debug(3, "Terminated.\n");
    exit 0;
}

# RELOAD: Calls a series of reload callbacks to refresh plugins' data.
sub reload {
    &debug(3, "Received reload call...\n");
    foreach(keys(%event_plugin_reload)) {
	&plugin_callback($_, $event_plugin_reload{$_});
    }
}

# ########### FILE OPERATIONS ############

# LOAD: This will load our rules.
sub load {
    &debug(3, "Loading $rulefile... ");
    $loaded = 0;
    if(open(RULES, $rulefile)) {
	foreach (keys(%chat_words)) {
	    delete $chat_words{$_};
	}
	foreach(<RULES>) {
	    chomp;
	    s/
//;
	    my @rule = split (/\t/);
	    $chat_words{"$rule[0]-\>$rule[1]"} = $rule[2];
	}
	close(RULES);
	&debug(3, "Rules loaded successfully!\n");
	$loaded = 1;
    } elsif (!-e $rulefile) {
	&debug(2, "File does not exist and will be created on save.\n");
	$loaded = 1;
    } else {
	&debug(1, "Cannot read from the rules file! This session will not be saved!\n");
    }
}

# SAVE: This will save our rules.
sub save {
    &debug(3, "Saving $rulefile... ");
    if ($loaded == 1) {
	if(open(RULES, ">$rulefile")) {
	    flock(RULES, 2);
	    foreach(keys(%chat_words)) {
		my ($a, $b) = split(/-\>/);
		$c = $chat_words{$_};
		print RULES "$a\t$b\t$c\n";
	    }
	    flock(RULES, 8);
	    close(RULES);
	    &debug(3, "Rules saved successfully!\n");
	} else {
	    &debug(1, "Cannot write to the rules file! This session will be lost!\n");
	}
    } else {
	&debug(2, "Opting not to save.  Rules are not loaded.\n");
    }
    $items = 0;
}

# ########### PLUGIN OPERATIONS ############

# PLUGIN_REGISTER: Registers a plugin (or doesn't).
sub plugin_register {
    my %data = @_;
    foreach (split(/,/, $data{modules})) {
	if (eval { eval "require $_"; }) {
	    &debug(4, $data{plugin_id} . ": $_ module was loaded as a plugin dependency\n");
	} else {
	    &debug(1, $data{plugin_id} . ": $_ module could not be loaded as a plugin dependency\n");
	    return 0;
	}
    } if $data{modules};
    if(!$plugin_type{$data{plugin_id}}) {
	&debug(4, $data{plugin_id} . ": no plugin conflicts detected\n");
    } else {
	&debug(1, $data{plugin_id} . ": a plugin is already registered to this handle\n");
	return 0;
    }
    $event_plugin_call{$data{plugin_id}} = $data{event_plugin_call};
    $plugin_type{$data{plugin_id}} = "EXT";
    if(!$data{plugin_desc}) {
	&debug(4, $data{plugin_id} . ": this plugin has no description and will be hidden\n");
    } else {
	$plugin_desc{$data{plugin_id}} = $data{plugin_desc};
    }
    if ($data{event_plugin_load}) {
	if (!&plugin_callback($data{plugin_id}, $data{event_plugin_load})) {
	    &debug(1, $data{plugin_id} . ": plugin returned an error code on load\n");
	    return 0;
	}
    }
    if ($data{event_plugin_unload}) {
	$event_plugin_unload{$data{plugin_id}} = $data{event_plugin_unload};
    }
    foreach (keys(%data)) {
	if ($_ =~ /^event_channel_.*/) {
	    ${$_}{$data{plugin_id}} = $data{$_};
        }
    }
    return 1;
}

# PLUGIN_CALLBACK: Calls the given plugin function with paramters.
sub plugin_callback {
    my ($plugin, $function, @params) = @_;
    if($plugin_type{$plugin} eq "EXT") {
	return &{"SimBot::plugin::$plugin\:\:$function"}($kernel, @params);
    } else {
	return &{$function}($kernel, @params);
    }
}
	    
# PRINT_HELP: Prints a list of valid commands privately to the user.
sub print_help {
    my $nick = $_[1];
    &debug(3, "Received help command from " . $nick . ".\n");
    foreach(sort {$a cmp $b} keys(%plugin_desc)) {
	$kernel->post(bot => privmsg => $nick, "%" . $_ . " - " . $plugin_desc{$_});
    }
}

# PRINT_LIST: Stupid replies.
sub print_list {
    my $nick = $_[1];
    &debug(3, "Received list command from " . $nick . ".\n");
    my @reply = (
		 "$nick: HER R TEH FIL3Z!!!! TEH PR1Z3 FOR U! KTHXBYE",
		 "$nick: U R L33T H4X0R!",
		 "$nick: No files for you!",
		 "$nick: Sorry, I have reached my piracy quota for this century.  Please return in " . (100 - ((localtime(time))[5] % 100)) . " years.",
		 "$nick: The FBI thanks you for your patronage.",
		 "$nick: h4x0r5 0n teh yu0r pC? oh nos!!! my megahurtz haev been stoeled!!!!!111 safely check yuor megahurtz with me, free!",
		 );
    $kernel->post(bot => privmsg => $channel, &pick(@reply));
}

# PRINT_STATS: Prints some useless stats about the bot to the channel.
sub print_stats {
    my %left;
    my %right;
    my @deadwords;
    my $count=0, $begins=0, $actions=0, $ends=0;
    my $message="";
    my @wordpop = ();
    &debug(3, "Received stats command from a user.\n");
    foreach(keys(%chat_words)) {
	my ($lhs, $rhs) = split(/->/, $_);
	if ($chat_words{$_} > $wordpop[1] && $_ !~ /(^__[A-Z]*|__.?[A-Z]*$)/) {
	    $wordpop[0] = $_;
	    $wordpop[1] = $chat_words{$_};
	}
	$left{$lhs} = 1;
	$right{$rhs} = 1;
	$begins++ if ($lhs =~ /^__.?BEGIN$/);
	$ends++ if ($rhs =~ /^__.?END$/);
	$actions++ if ($lhs eq "__ACTION");
    }
    foreach(keys(%left)) {
        $count++ unless $_ =~ /^__[A-Z]*/;
    }
    foreach(keys(%right)) {
        if (!$left{$_}) {
	    $count++ unless $_ =~ /^__[A-Z]*/;
	}
    }
    my ($wp_left, $wp_right) = split(/->/, $wordpop[0]);
    $kernel->post(bot => privmsg => $channel, "In total, I know $count words.  The most popular two word sequence is \"$wp_left $wp_right\" which has been used $wordpop[1] times.");
    $kernel->post(bot => privmsg => $channel, "I've learned $begins words that I can start a sentence with, and $ends words that I can end one with.  I know of $actions ways to start an IRC action (/me).");
    $count = 0;
    foreach(keys(%right)) {
	if(!$left{$_} && $_ !~ /^__.?END$/) {
	    $count++;
	    push(@deadwords, "'$_'");
	}
    }
    if ($count > 0) {
	$message .= "There are $count words that lead me to unexpected dead ends.";
	$message .= " They are: @deadwords";
    }
    $kernel->post(bot => privmsg => $channel, $message);
    $count=0;
    $message="";
    @deadwords = ();
    foreach(keys(%left)) {
	if(!$right{$_} && $_ !~ /^__.?BEGIN$/) {
	    $count++;
	    push(@deadwords, "'$_'");
	}
    }
    if ($count > 0) {
	$message .= "There are $count words that I no longer know how to use.";
	$message .= " They are: @deadwords";
    }
    $kernel->post(bot => privmsg => $channel, $message);
}

# ######### CONVERSATION LOGIC ###########

# BUILDRECORDS: This creates new rules and adds them to the database.
sub buildrecords {
    my $action = ($_[1] ? $_[1] : "");
    my @sentence = split(/\s+/, $_[0]);
    my ($sec) = localtime(time);
    $items++;

    my $tail = -1;
    while ($sentence[$tail] =~ /^[:;=].*/) {
        $tail--;
    }
    $sentence[$tail] =~ /([\!\?])[^\!\?]*$/;
    my $startblock = "__" . ($1 ? $1 : "") . "BEGIN";
    my $endblock = "__END";

    for(my $x=0; $x <= $#sentence; $x++) {
	$sentence[$x] =~ s/^[;:].*//;
	$sentence[$x] =~ s/^=[^=]+//;
	$sentence[$x] =~ s/[^\300-\377\w\'\/\-\.=\%\$&\+\@]*//g;
	$sentence[$x] =~ s/(^|\s)\.+|\.+(\s|$)//g;
        $sentence[$x] = lc($sentence[$x]);
	if ("@sentence" !~ /[A-Za-z0-9\300-\377]/) {
	    &debug(2, "This line contained no discernable words: @sentence\n");
	    goto skiptosave;
	}
	foreach (@chat_ignore) {
	    if ($sentence[$x] =~ /$_/) {
		&debug(2, "Not recording this line: @sentence\n");
		goto skiptosave;
	    }
	}
    }

    if ("@sentence" =~ /^\s*$/) {
	&debug(2, "This line contained no discernable words: @sentence\n");
	goto skiptosave;
    }
    if ($action eq "ACTION") {
	@sentence = ("__ACTION", @sentence);
    }
    @sentence = ($startblock, @sentence, $endblock);
    my $i = 0;
    while ($i < $#sentence) {
	if($sentence[$i+1] ne "") {
	    my $cur_word = $sentence[$i];
	    my $y = 0;
	    while ($cur_word eq "") {
		$y++;
		$cur_word = $sentence[$i-$y];
	    }
	    if ($chat_words{"$cur_word->$sentence[$i+1]"}) {
		$chat_words{"$cur_word->$sentence[$i+1]"}++;
		&debug(3, "Updating $cur_word-\>$sentence[$i+1] to " . $chat_words{"$cur_word-\>$sentence[$i+1]"} . "\n");
	    } else {
		$chat_words{"$cur_word->$sentence[$i+1]"} = 1;
		&debug(3, "Adding $cur_word-\>$sentence[$i+1]\n");
	    }
	}
	$i++;
    }
  skiptosave:
    if (($sec % 30) == 0 || $items >= 20) {
	&save;
    }
}

# BUILDREPLY: This creates a random reply from the database.
sub buildreply {
    if (%chat_words) {
	my @sentence = split(/ /, @_);
	my $newword = "";
	my $return = "";
	my $punc = "";
	while ($newword !~ /^__[\!\?]?END$/) {
	    my %choices = ();
	    my $chcount = 0;
	    foreach (keys(%chat_words)) {
		if (!$newword && $_ =~ /^(__[\!\?]?BEGIN)-\>.*/) {
		    $choices{$1} = 0 if !$choices{$1};
		    $choices{$1} += $chat_words{$_};
		    $chcount += $chat_words{$_};
		} elsif ($newword && $_ =~ /^\Q$newword\E-\>(.*)/) {
		    $choices{$1} = $chat_words{$_};
		    $chcount += $chat_words{$_};
		}
	    }
	    my $try = int(rand()*($chcount))+1;
	    foreach(sort {$a cmp $b} keys(%choices)) {
		$try -= $choices{$_};
		if ($try <= 0) {
		    $newword = $_;
		    if($newword =~ /^__([\!\?])?BEGIN$/) {
			if ($1) {
			    $punc = $1;
			    debug(3, "Using '$1' from __BEGIN\n");
			}
		    } elsif($newword =~ /^__([\!\?])?END$/) {
			if ($1 && !$punc) {
			    $punc = $1;
			    debug(3, "Using '$1' from __END\n");
			}
		    } else {
			$return .= $newword . " ";
		    }
		    last;
		}
	    }
	    if ($try > 0) {
		$newword = "__END";
		&debug(1, "Database problem!  Hit a dead end in \"$return\"...\n");
	    }
	}
	$return =~ s/\s+$//;
	$return = uc(substr($return, 0,1)) . substr($return, 1) . ($punc ne "" ? $punc : ".");
	$return =~ s/\bi(\b|\')/I$1/g;
	if (int(rand()*(100/$exsenpct)) == 0) {
	    &debug(3, "Adding another sentence...\n");
	    $return .= "__NEW__" . &buildreply(@sentence);
	}
	return $return;
    } else {
	&debug(1, "Could not form a reply.\n");
	return "I'm speechless.";
    }
}

# ######### IRC FUNCTION CALLS ###########

# INIT_BOT: After connecting to IRC, this will join the channel and
#           log the bot into channel services.
sub init_bot {
    &debug(3, "Setting invisible, masked user modes...\n");
    $kernel->call(bot => mode => $nickname, "+ix");
    if ($password) {
	&debug(3, "Logging into Channel Service as $username...\n");
	$kernel->call(bot => privmsg => "x\@channels.undernet.org", "login $username $password");
    }
    &debug(3, "Joining $channel...\n");
    $kernel->post(bot => join => $channel);
}

# PICK_NEW_NICK: If IRC reports the desired nickname as in use, this
#                will rotate the letters in the nickname to get a new one.
sub pick_new_nick {
    &debug(2, "Nickname " . $chosen_nick . " is unavailable!  Trying another...\n");
    $chosen_nick = substr($chosen_nick, -1) . substr($chosen_nick, 0, -1);
    $kernel->post(bot => nick => $chosen_nick);
}

# PROCESS_PING: Handle ping requests to the bot.
sub process_ping {
    my ($usermask, undef, $text) = @_[ ARG0, ARG1, ARG2 ];
    my ($nick) = split(/!/, $usermask);
    &debug(3, "Received ping request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'PING ' . $text);
}

# PROCESS_FINGER: Handle ping requests to the bot.
sub process_finger {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = "I have no fingers.  Please try again.";
    &debug(3, "Received finger request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'FINGER ' . $reply);
}

# PROCESS_TIME: Handle ping requests to the bot.
sub process_time {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = localtime(time);
    &debug(3, "Received time request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'TIME ' . $reply);
}

# PROCESS_VERSION: Handle ping requests to the bot.
sub process_version {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = `uname -s -r -m`;
    chomp($reply);
    &debug(3, "Received version request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, "VERSION $project $version ($reply)");
}

# PROCESS_PUBLIC: Handle messages sent to the channel.
sub process_public {

    my ($usermask, $channel, $text) = @_[ ARG0, ARG1, ARG2 ];
    my ($nick) = split(/!/, $usermask);
    $text =~ s/\003\d{0,2},?\d{0,2}//g;
    $text =~ s/[\002\017\026\037]//g;
    if ($text =~ /^[!\@].+/) {
	&debug(3, "Alerting " . $nick . " to use % in place of ! or @.\n");
	$kernel->post(bot => notice => $nick, "Commands must be prefixed with %.");
    } elsif ($text =~ /^\%/) {
	my @command = split(/\s/, $text);
	my $cmd = $command[0];
	$cmd =~ s/^%//;
	if ($event_plugin_call{$cmd}) {
	    &plugin_callback($cmd, $event_plugin_call{$cmd}, ($nick, $channel, @command));
	} else {
	    $kernel->post(bot => privmsg => $channel, "Hmm... @command isn't supported. Try \%help");
	}
    } elsif ($text =~ /^hi,*\s+($alttag|$nickname)[!\.\?]*/i) {
	&debug(3, "Greeting " . $nick . "...\n");
	$kernel->post(bot => privmsg => $channel, &pick(@greeting) . $nick . "!");
    } elsif ($text =~ /^($chosen_nick|$alttag|$nickname)([,|:]\s+|[!\?]*\s*([;:=][\Wdpo]*)?$)|,\s+($chosen_nick|$alttag|$nickname)[,\.!\?]\s+|,\s+($chosen_nick|$alttag|$nickname)[!\.\?]*\s*([;:=][\Wdpo]*)?$/i) {
	&debug(3, "Generating a reply for " . $nick . "...\n");
	my @botreply = split(/__NEW__/, &buildreply($text));
	my $queue = "";
	foreach $comment (@botreply) {
	    if ($comment =~ /__ACTION\s/) {
		$comment =~ s/$&//;
		$kernel->post(bot => privmsg => $channel, $queue) unless ($queue eq "");
		$kernel->post(bot => ctcp => $channel, 'ACTION', $comment);
		$queue = "";
	    } else {
		$queue .= $comment . " ";
	    }
	}
	$kernel->post(bot => privmsg => $channel, $queue) unless ($queue eq "");

    } elsif ($text !~ /^[;=:]/) {
	&debug(3, "Learning from " . $nick . "...\n");
	&buildrecords($text);
    }
    foreach(keys(%event_channel_public)) {
	&plugin_callback($_, $event_channel_public{$_}, ($nick, $channel, 'SAY', $text));
    }
}

# PROCESS_ACTION: Handle actions sent to the channel.
sub process_action {
    my ($usermask, undef, $text) = @_[ ARG0, ARG1, ARG2 ];
    my ($nick) = split(/!/, $usermask);
    &debug(3, "Learning from " . $nick . "'s action...\n");
    &buildrecords($text,"ACTION");
    foreach(keys(%event_channel_action)) {
	&plugin_callback($_, $event_channel_action{$_}, ($nick, $channel, 'ACTION', "$nick $text"));
    }
}

# PRCESS_PRIV: Handle private messages to the bot.
sub process_priv {
    my ($usermask, undef, $text) = @_[ ARG0, ARG1, ARG2 ];
    my ($nick) = split(/!/, $usermask);

    $kernel->post(bot => notice => $nick, "Please don't send me private messsages.");
}

# PRCESS_NOTICE: Handle notices to the bot.
sub process_notice {
    my ($usermask, undef, $text) = @_[ ARG0, ARG1, ARG2 ];
    my ($nick) = split(/!/, $usermask);

    if ($nick eq "X" && $password) {
	&debug(3, "Channel Service message: $text\n");
    }
}

# PING_EVENT: Check a few things on ping event.
sub ping_event {
    if ($nickname ne $chosen_nick) {
	$kernel->post(bot => ison => $nickname);
    }
}

# CHECK_NICKNAME: Check to see if nickname is free.
sub check_nickname {
    my @nicks = split(/ /, $_[ ARG1 ]);
    my $avail = 1;
    foreach (@nicks) {
	if ($_ eq $nickname) {
	    $avail = 0;
	}
    }
    if ($avail == 1) {
	$kernel->post(bot => nick => $nickname);
	&debug(3, "Nickname " . $nickname . " is available!  Attempting to recover it...\n");
	$chosen_nick = $nickname;
    }
}

#CHECK_KICK: If the bot is kicked, rejoin.
sub check_kick {
    my ($nick) = $_[ ARG2 ];
    my $kicker = $_[ ARG0 ];
    my $reason = $_[ ARG3 ];
    ($kicker, undef) = split(/!/, $kicker, 2);
    if ($nick eq $chosen_nick) {
	&debug(2, "Kicked from $channel... Attempting to rejoin!\n");
	$kernel->post(bot => join => $channel);
    }
    
    foreach(keys(%event_channel_kick)) {
	&plugin_callback($_, $event_channel_kick{$_}, ($nick, $channel, 'KICKED', $reason, $kicker));
    }
}

#REQUEST_INVITE: Ask channel service for an invitation
sub request_invite {
    if ($password) {
	&debug(2, "Could not rejoin.  Asking channel service...\n");
	$kernel->post(bot => privmsg => "x", "invite $channel");
    }
}

#CHECK_INVITE: Check to see if an invite should be accepted
sub check_invite {
    my ($chan) = $_[ ARG1 ];
    if ($chan eq $channel) {
	$kernel->post(bot => join => $channel);
    }
}



# ######### CONNECTION SUBROUTINES ###########

# QUIT: Quit IRC.
sub quit {
    my $message = "@_";
    $terminating = 1;
    $kernel->call(bot => quit => "$project $version: $message");
    $kernel->post(bot => unregister => "all");
    &debug(2, "Quitting IRC... $message\n");
}

# RECONNECT: Reconnect to IRC when disconnected.
sub reconnect {
    if ($terminating == 1) {
	&debug(2, "Disconnected!\n");
    } else {
	&debug(2, "Disconnected!  Reconnecting in 30 seconds...\n");
	$chosen_server = &pick(@server);
	sleep 30;
	$kernel->post(bot => 'connect',
		      {
			  Nick    => $chosen_nick,
			  Server  => $chosen_server,
			  Port    =>  6667,
			  Ircname => "$project $version",
			  Username => $username,
		      }
		      );
	&debug(3, "Connecting to IRC server " . $chosen_server . "...\n");
    }

}

# MAKE_CONNECTION: Starts up the connection to IRC.
sub make_connection {
    &debug(3, "Setting up the IRC connection...\n");
    
    $kernel->post(bot => register => "all");
    $chosen_nick = $nickname;
    
    $chosen_server = &pick(@server);
    $kernel->post(bot => 'connect',
		  {
		      Nick    => $chosen_nick,
		      Server  => $chosen_server,
		      Port    =>  6667,
		      Ircname => "$project $version",
		      Username => $username,
		  }
		  );
    &debug(3, "Connecting to IRC server " . $chosen_server . "...\n");
}

while ($terminating != 1) {
    $kernel->run();
}
exit 0;
