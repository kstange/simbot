#!/usr/bin/perl

# SimBot
#
# Copyright (C) 2002-04, Kevin M Stange <kevin@simguy.net>
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

# Declaring these as empty is better for the case when the config file
# is missing them.
@greeting = ();
@chat_ignore = ();
$services_type = "";

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

# ****************************************
# ************ Start of Script ***********
# ****************************************

# We want to catch signals to make sure we clean up and save if the
# system wants to kill us.
$SIG{'TERM'} = 'SimBot::cleanup';
$SIG{'INT'}  = 'SimBot::cleanup';
$SIG{'HUP'}  = 'SimBot::cleanup';
$SIG{'USR1'} = 'SimBot::restart';
$SIG{'USR2'} = 'SimBot::reload';

# These are intializations of the hash tables we'll be using for
# callbacks and plugin information.  We'll initialize the built-in
# plugins here, since there's no need to do registration checks.

# This is the plugin's type.  A plugin cannot currently set this
# itself, meaning only internal plugins can be anything but "EXT"
%plugin_type = (
		"stats",   "INT",
		"help",    "INT",
		"list",    "INT",
		);

# This provides the descriptions of plugins.  If a plugin has no
# defined description, it is "hidden" and will not appear in help.
%plugin_desc = (
		"stats",   "Shows useless stats about the database.",
		"help",    "Shows this message.",
		);

# These are the events you can currently attach to.

### Plugin Events ###
# Plugin events get params:
#  (kernel)
%event_plugin_load     = ();
%event_plugin_reload   = ();
%event_plugin_unload   = ();
# Call event gets params:
#  (kernel, from, channel, command string)
%event_plugin_call     = (
			  "stats",   "print_stats",
			  "help",    "print_help",
			  "list",    "print_list",
			  );

### Channel Events ###
# Channel events get params:
#  (kernel, from, channel, eventname, params)
%event_channel_message = (); # eventname = SAY (text)
%event_channel_action  = (); # eventname = ACTION (text)
%event_channel_notice  = (); # eventname = NOTICE (text)
%event_channel_kick    = (); # eventname = KICKED (text, kicker)
%event_channel_mode    = (); # eventname = MODE (modes, arguments...)
%event_channel_topic   = (); # eventname = TOPIC (text)
%event_channel_join    = (); # eventname = JOINED ()
%event_channel_part    = (); # eventname = PARTED (message)
%event_channel_quit    = (); # eventname = QUIT (message)
%event_channel_mejoin  = (); # eventname = JOINED ()
%event_channel_nojoin  = (); # eventname = NOTJOINED ()
%event_channel_novoice = (); # eventname = CANTSAY ()
%event_channel_invite  = (); # eventname = INVITED ()

### Private Events ###
# Private events get params:
#  (kernel, from, eventname, text)
%event_private_message = (); # eventname = PRIVMSG (text)
%event_private_action  = (); # eventname = ACTION (text)
%event_private_notice  = (); # eventname = NOTICE (text)

### Server Events ###
# Server events get params:
#  (kernel, server, nickname, params)
%event_server_connect  = (); # ()
%event_server_ping     = (); # ()
%event_server_ison     = (); # (nicks list...)

@list_nicks_ison       = (
			  $nickname,
			  );

# Now that we've initialized the callback tables, let's load
# all the plugins that we can from the plugins directory.
opendir(DIR, "./plugins");
foreach(readdir(DIR)) {
    if($_ =~ /.*\.pl$/) {
	if($_ =~ /^services\.(.+)\.pl$/) {
	    debug(4, "$1 services plugin found.\n");
	    if ($services_type eq $1) {
		debug(4, "$1 services plugin was selected. Attempting to load...\n");
		if (eval { require "./plugins/$_"; }) {
		    debug(3, "$1 services plugin loaded successfully.\n");
		} else {
		    debug(1, "$@");
		    debug(2, "$1 service plugin did not load due to errors.\n");
		}
	    } else {
		debug(4, "$1 services plugin was not selected.\n");
	    }
	} elsif(eval { require "./plugins/$_"; }) {
	    debug(3, "$_ plugin loaded successfully.\n");
	} else {
	    debug(1, "$@");
	    debug(2, "$_ plugin did not load due to errors.\n");
	}
    }
}
closedir(DIR);

# Here are some globals that should be initialized because someone
# might try to look at them before they get set to something.
$loaded      = 0; # The rules are not loaded yet.
$items       = 0; # We haven't seen any lines yet.
$terminating = 0; # We are not terminating in the default case.

# Load the massive table of rules simbot will need.
&load;

# Now that everything is loaded, let's prepare to connect to IRC.
# We'll need this perl module to be able to do anything meaningful.
$kernel = new POE::Kernel;
use POE;
use POE::Component::IRC;

# Create a new IRC connection.
POE::Component::IRC->new('bot');

# Add the handlers for different IRC events we want to know about.
POE::Session->new
  ( _start           => \&make_connection,
    irc_disconnected => \&reconnect,
    irc_socketerr    => \&reconnect,
    irc_433          => \&pick_new_nick,    # nickname in use
    irc_001          => \&server_connect,   # connected
    irc_ping         => \&server_ping,      # we can use this as a timer
    irc_303          => \&server_ison,      # check ison reply
    irc_msg          => \&private_message,
    irc_public       => \&channel_message,
    irc_kick         => \&channel_kick,
    irc_join         => \&channel_join,
    irc_part         => \&channel_part,
    irc_quit         => \&channel_quit,
    irc_404          => \&channel_novoice,  # we can't speak for some reason
    irc_471          => \&channel_nojoin,   # channel is at limit
    irc_473          => \&channel_nojoin,   # channel invite only
    irc_474          => \&channel_nojoin,   # banned from channel
    irc_475          => \&channel_nojoin,   # bad channel key
    irc_invite       => \&channel_invite,
    irc_topic        => \&channel_topic,
    irc_mode         => \&channel_mode,
    irc_notice       => \&process_notice,
    irc_ctcp_action  => \&process_action,
    irc_ctcp_version => \&process_version,
    irc_ctcp_time    => \&process_time,
    irc_ctcp_finger  => \&process_finger,
    irc_ctcp_ping    => \&process_ping,
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
		  "SPAM: ",
		  );
    if ($_[0] <= $verbose) {
	print STDERR $errors[$_[0]] . $_[1];
    }
}

# PICK: Pick a random item from an array.
sub pick {
    return @_[int(rand()*@_)];
}

# HOSTMASK: Generates a 'type 3' hostmask from a nick!user@host address
sub hostmask {
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
    if($seconds >= 60) {
        $minutes = int $seconds / 60;
        $seconds %= 60;
        if($minutes >= 60) {
            $hours = int $minutes / 60;
            $minutes %= 60;
            if($hours >= 24) {
                $days = int $hours / 24;
                $hours %= 24;
                if($days >= 365) {
                    $years = int $days/365;
                    $days %= 365;
                }
            }
        }
    }

    my @reply;
    push(@reply, "$years year" . (($years == 1) ? '' : 's'))       if $years;
    push(@reply, "$days day" . (($days == 1) ? '' : 's'))          if $days;
    push(@reply, "$hours hour" . (($hours == 1) ? '' : 's'))       if $hours;
    push(@reply, "$minutes minute" . (($minutes == 1) ? '' : 's')) if $minutes;
    push(@reply, "$seconds second" . (($seconds == 1) ? '' : 's')) if $seconds;
    if(@reply) {
	my $string = join(', ', @reply) . ' ago';
	$string =~ s/(.*),/$1 and/;
	return $string;
    } else {
        return 'very recently';
    }
}

# RESTART: Quits and restarts the script.  This should be done
#          after the script is updated.
sub restart {
    &debug(3, "Received restart call...\n");
    foreach(keys(%event_plugin_unload)) {
	&plugin_callback($_, $event_plugin_unload{$_});
    }
    &debug(3, "Disconnecting from IRC...\n");
    &quit("Restarting, brb...");
    &save;
    &debug(3, "Restarting script...\n");
    exec "./simbot.pl";
}

# CLEANUP: Terminates the script immediately after saving.
sub cleanup {
    &debug(3, "Received cleanup call...\n");
    foreach(keys(%event_plugin_unload)) {
	&plugin_callback($_, $event_plugin_unload{$_});
    }
    &debug(3, "Disconnecting from IRC...\n");
    &quit("Bye everyone!");
    &save;
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
	foreach(<RULES>) {
	    chomp;
	    s/\r//;
	    my @rule = split (/\t/);
	    $chat_words{$rule[0]}{$rule[1]}[1] = $rule[2];
	    $chat_words{$rule[1]}{$rule[0]}[0] = $rule[2];
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
		my $a = $_;
		foreach(keys(%{$chat_words{$a}})) {
		    my $b = $_;
		    my $c = $chat_words{$a}{$b}[1];
		    print RULES "$a\t$b\t$c\n";
		}
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
    if ($data{modules}) {
	foreach (split(/,/, $data{modules})) {
	    if (eval { eval "require $_"; }) {
		&debug(4, $data{plugin_id} . ": $_ module was loaded as a plugin dependency\n");
	    } else {
		&debug(1, $data{plugin_id} . ": $_ module could not be loaded as a plugin dependency\n");
		return 0;
	    }
	}
    }
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
	if ($_ =~ /^event_(channel|private|server)_.*/) {
	    ${$_}{$data{plugin_id}} = $data{$_};
        } elsif ($_ =~ /^list_.*/) {
	    my @list = split(/,\s*/, $data{$_});
	    push(@{$_}, @list);
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
    my @ldeadwords;
    my @rdeadwords;
    my $message;

    &debug(3, "Received stats command from a user.\n");
    my $count = keys(%chat_words);
    my $begins = keys(%{$chat_words{'__BEGIN'}}) + keys(%{$chat_words{'__!BEGIN'}}) + keys(%{$chat_words{'__?BEGIN'}});
    my $ends = keys(%{$chat_words{'__END'}}) + keys(%{$chat_words{'__!END'}}) + keys(%{$chat_words{'__?END'}});
    my $actions = keys(%{$chat_words{'__ACTION'}});
    $kernel->post(bot => privmsg => $channel, "In total, I know $count words.  I've learned $begins words that I can start a sentence with, and $ends words that I can end one with.  I know of $actions ways to start an IRC action (/me).");
    my $lfound, $lcount = 0;
    my $rfound, $rcount = 0;
    my $wordpop;
    my $wordpopcount = 0;

    foreach $word (keys(%chat_words)) {
	next if ($word =~ /^__[\!\?]?[A-Z]*$/);
	$lfound = 0;
	$rfound = 0;
	foreach (keys(%{$chat_words{$word}})) {
	    if (defined $chat_words{$word}{$_}[1]) {
		$rfound = 1;
	    }
	    if (defined $chat_words{$word}{$_}[0]) {
		$lfound = 1;
	    }
	    if ($chat_words{$word}{$_}[1] > $wordpopcount
		&& $_ !~ /^__[\!\?]?[A-Z]*$/) {
		$wordpop = "$word $_";
		$wordpopcount = $chat_words{$word}{$_}[1];
	    }
	}
	if ($lfound == 0) {
	    $lcount++;
	    push(@ldeadwords, "'$word'");
	}
	if ($rfound == 0) {
	    $rcount++;
	    push(@rdeadwords, "'$word'");
	}
    }
    $kernel->post(bot => privmsg => $channel, "The most popular two word sequence is \"$wordpop\" which has been used $wordpopcount times.");
    if ($rcount > 0) {
	$kernel->post(bot => privmsg => $channel, "There are $rcount words that lead me to unexpected dead ends. They are: @rdeadwords");
    }
    if ($lcount > 0) {
	$kernel->post(bot => privmsg => $channel, "There are $lcount words that lead me to unexpected dead beginnings.  They are: @ldeadwords");
    }
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
	    if ($chat_words{$cur_word}{$sentence[$i+1]}[1]) {
		$chat_words{$cur_word}{$sentence[$i+1]}[1]++;
		$chat_words{$sentence[$i+1]}{$cur_word}[0]++;
		&debug(3, "Updating $cur_word-\>$sentence[$i+1] to " . $chat_words{$cur_word}{$sentence[$i+1]}[1] . "\n");
		&debug(4, "Updating $sentence[$i+1]-\>$cur_word to " . $chat_words{$sentence[$i+1]}{$cur_word}[0] . " (reverse)\n");
	    } else {
		$chat_words{$cur_word}{$sentence[$i+1]}[1] = 1;
		$chat_words{$sentence[$i+1]}{$cur_word}[0] = 1;
		&debug(3, "Adding $cur_word-\>$sentence[$i+1]\n");
		&debug(4, "Adding $sentence[$i+1]-\>$cur_word (reverse)\n");
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
	my @sentence = split(/ /, $_[0]);

	# find an interesting word to base the sentence off
	my $newword = &find_interesting_word(@sentence);

	my $middleword = $newword;
	my $return = ($newword ? "$newword " : "");
	my $punc = "";
	while ($newword !~ /^__[\!\?]?END$/) {
	    my $chcount = 0;
	    if (!$newword) {
		my %choices = ("__BEGIN", 0,
			       "__!BEGIN", 0,
			       "__?BEGIN", 0,
			       );
		foreach $key (keys(%choices)) {
		    foreach (keys(%{$chat_words{$key}})) {
			$choices{$key} = 0 if !$choices{$key};
			$choices{$key} += $chat_words{$key}{$_}[1];
		    }
		    $chcount += $choices{$key};
		}
		my $try = int(rand()*($chcount))+1;
		foreach(sort {$a cmp $b} keys(%choices)) {
		    $try -= $choices{$_};
		    if ($try <= 0) {
			$newword = $_;
			m/^__([\!\?])?BEGIN$/;
			if ($1) {
			    $punc = $1;
			    debug(3, "Using '$1' from __BEGIN\n");
			}
		    }
		}
	    }
	    $chcount = 0;
	    if ($newword) {
		foreach (keys(%{$chat_words{$newword}})) {
    		    $chcount += $chat_words{$newword}{$_}[1];
		}
		debug(4, "$chcount choices for next to $newword\n");
	    }
	    my $try = int(rand()*($chcount))+1;
	    foreach(sort {$a cmp $b} keys(%{$chat_words{$newword}})) {
    		$try -= $chat_words{$newword}{$_}[1];
    		if ($try <= 0) {
		    debug(4, "Selected $_ to follow $newword\n");
    		    $newword = $_;
    		    if($newword =~ /^__([\!\?])?END$/) {
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
	} # ENDS while

	if($middleword) {
	    $newword = $middleword;
	    while ($newword !~ /^__[\!\?]?BEGIN$/) {
		my $chcount = 0;
		foreach (keys(%{$chat_words{$newword}})) {
		    $chcount += $chat_words{$newword}{$_}[0];
		    debug(4, "$chcount choices for next to $newword\n");
		}
		my $try = int(rand()*($chcount))+1;
		foreach(sort {$a cmp $b} keys(%{$chat_words{$newword}})) {
		    $try -= $chat_words{$newword}{$_}[0];
		    if ($try <= 0) {
			debug(4, "Selected $_ to follow $newword\n");
			$newword = $_;
			if($newword =~ /^__([\!\?])?BEGIN$/) {
			    if ($1) {
				$punc = $1;
				debug(3, "Using '$1' from __BEGIN\n");
			    }
			} else {
			    $return = $newword . " " . $return;
			}
			last;
		    }
		}
		if ($try > 0) {
		    $newword = "__BEGIN";
		    &debug(1, "Database problem!  Hit a dead beginning in \"$return\"...\n");
		}
	    } # ENDS while
	}
	$return =~ s/\s+$//;
	$return = uc(substr($return, 0,1)) . substr($return, 1) . ($punc ne "" ? $punc : ".");
	$return =~ s/\bi(\b|\')/I$1/g;
	if ($exsenpct && int(rand()*(100/$exsenpct)) == 0) {
	    &debug(3, "Adding another sentence...\n");
	    $return .= "__NEW__" . &buildreply("");
	}
	return $return;
    } else {
	&debug(1, "Could not form a reply.\n");
	return "I'm speechless.";
    }
}

# FIND_INTERESTING_WORD: Finds a word to base a sentence off
sub find_interesting_word {
    my $curWordScore, $curTableWordA, $curTableWordB, $highestScoreWord,
        $highestScore, $wordFound, $curWord, $curTableKey;
    debug(3, "Word scores: ");
    $highestScoreWord = ""; $highestScore=0;
    foreach $curWord (@_) {
        $curWord = lc($curWord);
        $curWord =~ s/[,\.\?\!\:]*$//;
        if(length($curWord) <= 3
	   || !defined $chat_words{$curWord}
           || $curWord =~ /^($chosen_nick|$alttag|$nickname)$/i) {
            next;
        }
        $curWordScore = 5000;
	foreach $nextWord (keys(%{$chat_words{$curWord}})) {
	    if($nextWord =~ /__[\.\?\!]?(END|BEGIN)$/) {
		$curWordScore -= 1.8 * $chat_words{$curWord}{$nextWord}[1];
		$curWordScore -= 1.8 * $chat_words{$curWord}{$nextWord}[0];
	    } else {
		$curWordScore -= $chat_words{$curWord}{$nextWord}[1];
            }
        }
        $curWordScore += .7 * length($curWord);
        debug(3, "$curWord:$curWordScore ");
        if($curWordScore > $highestScore) {
            $highestScore = $curWordScore;
            $highestScoreWord = $curWord;
        }
    }
    debug(3, "\nUsing $highestScoreWord\n");
    return $highestScoreWord;
}

# SEND_PIECES: This will break the message up into blocks of no more
# than 450 characters and send them separately.  This works around
# IRC message limitations.
sub send_pieces {
    my ($dest, $prefix, $text) = @_;
    my @words = split(/\s/, $text);
    my $line = "";
    foreach(@words) {
	if (length($line) == 0) {
	    $line = ($prefix ? $prefix : "") . "$_";
	} elsif (length($line) + length($_) + 1 <= 450) {
	    $line .= " $_";
	} else {
	    $kernel->post(bot => privmsg => $dest, $line);
	    $line = ($prefix ? $prefix : "") . "$_";
	}
    }
    $kernel->post(bot => privmsg => $dest, $line);
}

# ######### IRC FUNCTION CALLS ###########

# SERVER_CONNECT: After connecting to IRC, this will join the channel and
# log the bot into channel services.
sub server_connect {
    &debug(3, "Setting invisible user mode...\n");
    $kernel->call(bot => mode => $chosen_nick, "+i");
    foreach(keys(%event_server_connect)) {
	&plugin_callback($_, $event_server_connect{$_}, ($chosen_server, $chosen_nick));
    }
    &debug(3, "Joining $channel...\n");
    $kernel->post(bot => join => $channel);
}
# SERVER_PING: Allow for certain processes to be run on a regular IRC event,
# the ping event.
sub server_ping {
    foreach(keys(%event_server_ping)) {
	&plugin_callback($_, $event_server_ping{$_}, ($chosen_server, $chosen_nick));
    }
    $kernel->post(bot => ison => @list_nicks_ison);
}

# SERVER_ISON: Process the ISON reply from the server.  We'll use this to
# recover the bot's desired nickname if it becomes available.  Plugins can
# also add nicknames to this list and see whether or not they are online
# periodically.
sub server_ison {
    my @nicks = split(/ /, $_[ ARG1 ]);
    my $avail = 1;
    &debug(4, "Nicknames online: @nicks\n");

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
    foreach(keys(%event_server_ison)) {
	&plugin_callback($_, $event_server_ison{$_}, ($chosen_server, $chosen_nick, @nicks));
    }
}

# PROCESS_PING: Handle ping requests to the bot.
sub process_ping {
    my ($nick) = split(/!/, $_[ARG0]);
    my $text = $_[ ARG2 ];
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

# PROCESS_NOTICE: Handle notices to the bot.
sub process_notice {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($target, $text) = @_[ ARG1, ARG2 ];
    my $public = 0;
    foreach(@{$target}) {
	if($_ =~ /[\#\&].+/) {
	    $public = 1;
	}
    }
    if($public) {
	&debug(4, "Received public notice from $nick.\n");
	foreach(keys(%event_channel_notice)) {
	    &plugin_callback($_, $event_channel_notice{$_}, ($nick, $channel, 'NOTICE', $text));
	}
    } else {
	&debug(4, "Received private notice from $nick.\n");
	foreach(keys(%event_private_notice)) {
	    &plugin_callback($_, $event_private_notice{$_}, ($nick, 'NOTICE', $text));
	}
    }
}

# PROCESS_ACTION: Handle actions sent to the channel.
sub process_action {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($target, $text) = @_[ ARG1, ARG2 ];
    my $public = 0;
    foreach(@{$target}) {
	if($_ =~ /[\#\&].+/) {
	    $public = 1;
	}
    }
    if($public) {
	&debug(3, "Learning from " . $nick . "'s action...\n");
	&buildrecords($text,"ACTION");
	foreach(keys(%event_channel_action)) {
	    &plugin_callback($_, $event_channel_action{$_}, ($nick, $channel, 'ACTION', "$nick $text"));
	}
    } else {
	debug(4, "Received private action from $nick.\n");
	foreach(keys(%event_private_action)) {
	    &plugin_callback($_, $event_private_action{$_}, ($nick, 'ACTION', "$nick $text"));
	}
    }
}

# PRIVATE_MESSAGE: Handle private messages to the bot.
sub private_message {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my $text = $_[ ARG2 ];
    foreach(keys(%event_private_message)) {
	&plugin_callback($_, $event_private_message{$_}, ($nick, 'PRIVMSG', $text));
    }
}

# CHANNEL_MESSAGE: Handle messages sent to the channel.
sub channel_message {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($channel, $text) = @_[ ARG1, ARG2 ];
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
		if($cmd =~ m/[a-z]/) {
			$kernel->post(bot => privmsg => $channel, "Hmm... @command isn't supported. Try \%help");
		}
		# otherwise, command has no letters in it, and therefore was probably a smile %-) (a very odd smile, sure, but whatever)
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
    foreach(keys(%event_channel_message)) {
	&plugin_callback($_, $event_channel_message{$_}, ($nick, $channel, 'SAY', $text));
    }
}

# CHANNEL_KICK: If the bot is kicked, rejoin the channel.  Also let
# inquiring plugins know about kick events.
sub channel_kick {
    my ($kicker) = split(/!/, $_[ ARG0 ]);
    my ($chan, $nick, $reason) = @_[ ARG1, ARG2, ARG3 ];
    if ($nick eq $chosen_nick && $chan eq $channel) {
	&debug(2, "Kicked from $channel... Attempting to rejoin!\n");
	$kernel->post(bot => join => $chan);
    }

    foreach(keys(%event_channel_kick)) {
	&plugin_callback($_, $event_channel_kick{$_}, ($nick, $chan, 'KICKED', $reason, $kicker));
    }
}

# CHANNEL_INVITE: Process a channel invitation from a user.
sub channel_invite {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my $chan = $_[ ARG1 ];
    foreach(keys(%event_channel_invite)) {
	&plugin_callback($_, $event_channel_invite{$_}, ($nick, $chan, 'INVITED'));
    }
    if ($chan eq $channel) {
	$kernel->post(bot => join => $channel);
    }
}

# CHANNEL_NOJOIN: Allow plugins to take actions on failed join attempt.
sub channel_nojoin {
    foreach(keys(%event_channel_nojoin)) {
	&plugin_callback($_, $event_channel_nojoin{$_}, ($chosen_nick, $channel, 'NOTJOINED'));
    }
}

# CHANNEL_JOIN: Allow plugins to take actions on successful join attempt.
sub channel_join {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my $chan = $_[ ARG1 ];
    if ($nick eq $chosen_nick) {
	&debug(3, "Successfully joined $chan.\n");
	foreach(keys(%event_channel_mejoin)) {
	    &plugin_callback($_, $event_channel_mejoin{$_}, ($nick, $chan, 'JOINED'));
	}
    } else {
	&debug(4, "$nick has joined $chan.\n");
	foreach(keys(%event_channel_join)) {
	    &plugin_callback($_, $event_channel_join{$_}, ($nick, $chan, 'JOINED'));
	}
    }
}

# CHANNEL_PART: Allow plugins to take actions when a user parts the channel.
sub channel_part {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $message) = split(/ :/, $_[ ARG1 ], 2);
    &debug(4, "$nick has parted $chan. ($message)\n");
    foreach(keys(%event_channel_part)) {
	&plugin_callback($_, $event_channel_part{$_}, ($nick, $chan, 'PARTED', $message));
    }
}

# CHANNEL_QUIT: Allow plugins to take actions when a user parts the channel.
sub channel_quit {
    my $message = $_[ ARG1 ];
    my ($nick) = split(/!/, $_[ ARG0 ]);
    &debug(4, "$nick has quit IRC. ($message)\n");
    foreach(keys(%event_channel_quit)) {
	&plugin_callback($_, $event_channel_quit{$_}, ($nick, undef, 'QUIT', $message));
    }
}

# CHANNEL_NOVOICE: Allow plugins to take actions when the bot cannot speak.
sub channel_novoice {
    my ($chan) = split(/ :/, $_[ ARG1 ]);
    &debug(2, "Last message could not be sent to $chan.\n");
    foreach(keys(%event_channel_novoice)) {
	&plugin_callback($_, $event_channel_novoice{$_}, ($chosen_nick, $chan, 'CANTSAY'));
    }
}

# CHANNEL_TOPIC: Allow plugins to take actions when the topic is changed.
sub channel_topic {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $text) = @_[ ARG1, ARG2 ];
    &debug(4, "Topic in $chan was changed to '$text' by $nick.\n");
    foreach(keys(%event_channel_topic)) {
	&plugin_callback($_, $event_channel_topic{$_}, ($nick, $chan, 'TOPIC', $text));
    }
}

# CHANNEL_MODE: Allow plugins to take actions when the channel modes change.
sub channel_mode {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $modes, @args) = @_[ ARG1, ARG2, ARG3 .. $#_ ];
    if ($nick ne $chan) {
	&debug(4, "$nick set mode $modes @args in $chan.\n");
	foreach(keys(%event_channel_mode)) {
	    &plugin_callback($_, $event_channel_mode{$_}, ($nick, $chan, 'MODE', $modes, @args));
	}
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

# PICK_NEW_NICK: If IRC reports the desired nickname as in use, this
#                will rotate the letters in the nickname to get a new one.
sub pick_new_nick {
    &debug(2, "Nickname " . $chosen_nick . " is unavailable!  Trying another...\n");
    $chosen_nick = substr($chosen_nick, -1) . substr($chosen_nick, 0, -1);
    $kernel->post(bot => nick => $chosen_nick);
}

while ($terminating != 1) {
    $kernel->run();
}
exit 0;
