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

require "./config.pl";

# Check some config options or bail out!
die("Your config.pl is lacking an IRC server to connect to!") unless @server;
die("Your config.pl is lacking a channel to join!") unless $channel;
die("Your config.pl is lacking a valid default nickname!") unless (length($nickname) >= 2);
die("Your config.pl has a extra sentence % >= 100%!") unless ($exsenpct < 100);
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

@todo = (
	 "1) %delete: allow users to delete words used less than x times",
	 "2) %recap: allow users to request scrollback of up to x lines",
	 "3) create a means for automatic dead words cleanup",
	 "4) add detection for the return of X and log back in",
	 "5) automatically perform regular db backups",
	 "6) split out a plugin architecture",
	 "--- Finish above this line and we'll increment to 6.0 final ---",
	 "7) maybe: grab contextual hinting",
	 "8) maybe: do some runaway loop detection",
	 "9) pray for IRC module to start supporting QUIT properly",
	 );

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

%plugin = (
	   "%stats",   "print_stats",
	   "%help",    "print_help",
	   "%todo",    "print_todo",
	   "%list",    "print_list",
	   );

%plugin_desc = (
		"%stats",   "Shows useless stats about the database",
		"%help",    "Shows this message",
		"%todo",    "Where the hell am I going?",
		);		

# We'll need this perl module to be able to do anything meaningful.
$kernel = new POE::Kernel;
use POE;
use POE::Component::IRC;

# Find needs LWP to be useable.
if (eval { require LWP::UserAgent; }) {
    $plugin{"%find"} = "google_find";
    $plugin_desc{"%find"} = "Searches Google with \"I'm Feeling Lucky\"";
    debug(3, "LWP::UserAgent loaded: Find plugin will be used\n");
} else {
    debug(3, "LWP::UserAgent failed: Find plugin will not be available\n");
}

# We want to catch signals to make sure we clean up and save if the
# system wants to kill us.
$SIG{'TERM'} = 'cleanup';
$SIG{'INT'}  = 'cleanup';
$SIG{'HUP'}  = 'cleanup';
$SIG{'USR1'} = 'restart';

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

# RESTART: Quits and restarts the script.  This should be done
#          after the script is updated.
sub restart {
    &debug(3, "Received restart call...\n");
    &save;
    &cleanup_seen;
    &debug(3, "Disconnecting from IRC...\n");
    &quit("Restarting, brb...");
    &debug(3, "Restarting script...\n");
    exec "./simbot.pl";
}

# CLEANUP: Terminates the script immediately after saving.
sub cleanup {
    &debug(3, "Received cleanup call...\n");
    &save;
    &cleanup_seen;
    &debug(3, "Disconnecting from IRC...\n");
    &quit("Bye everyone!");
    &debug(3, "Terminated.\n");
    exit 0;
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

# GOOGLE_FIND: Prints a URL returned by google's I'm Feeling Lucky.
sub google_find {
    my ($nick, @terms) = @_;
    shift(@terms);
    my $query = "@terms";
    $query =~ s/\&/\%26/g;
    $query =~ s/\%/\%25/g;
    $query =~ s/\+/\%2B/g;
    $query =~ s/\s/+/g;
    my $url = "http://www.google.com/search?q=" . $query . "&btnI=1&safe=active";
    &debug(3, "Received find command from " . $nick . ".\n");
    my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
    $useragent->agent("$project/1.0");
    $useragent->timeout(5);
    my $request = HTTP::Request->new(GET => $url);
    my $response = $useragent->request($request);
    if ($response->previous) {
	if ($response->previous->is_redirect) {
	    $kernel->post(bot => privmsg => $channel, "$nick: " . $response->request->uri());
	} else {
	    $kernel->post(bot => privmsg => $channel, "$nick: An unknown error occured retrieving results.");
	}
    } elsif (!$response->is_error) {
	# Let's use the calculator!
	if ($response->content =~ m#/images/calc_img\.gif#) {
	    $response->content =~ m#<td nowrap><font size=\+1><b>(.*?)</b></td>#;
	    # We can't just take $1 because it might have HTML in it
	    my $result = $1;
	    $result =~ s#<sup>(.*?)</sup>#^$1#g;
	    $result =~ s#<font size=-2> </font>#,#g;
	    $result =~ s#&times;#x#g;
	    $kernel->post(bot => privmsg => $channel, "$nick: $result");
	} else {
	    $kernel->post(bot => privmsg => $channel, "$nick: Nothing was found.");
	}
    } else {
	$kernel->post(bot => privmsg => $channel, "$nick: Sorry, I could not access Google.");
    }
}

# PRINT_HELP: Prints a list of valid commands privately to the user.
sub print_help {
    my $nick = $_[0];
    &debug(3, "Received help command from " . $nick . ".\n");
    foreach(sort {$a cmp $b} keys(%plugin_desc)) {
	$kernel->post(bot => privmsg => $nick, $_ . " - " . $plugin_desc{$_});
    }
}

# PRINT_LIST: Stupid replies.
sub print_list {
    my $nick = $_[0];
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

# PRINT_TODO: Prints todo list privately to the user.
sub print_todo {
    my $nick = $_[0];
    &debug(3, "Received todo command from " . $nick . ".\n");
    if (@todo) {
	foreach(@todo) {
	    $kernel->post(bot => privmsg => $nick, $_);
	}
    } else {
	$kernel->post(bot => privmsg => $nick, "Request some features!  My todo list is empty!");
    }
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

### BEGIN seen stuff
dbmopen (%seenData, 'seen', 0664) || die("Can't open dbm\n");

$plugin{'%seen'} = "get_seen";
$plugin_desc{'%seen'} = 'Tells you the last time I saw someone.';
# GET_SEEN: Checks to see if a person has done anything lately...
sub get_seen {
    my ($nick, undef, $person) = @_;
    if(!$person) {
        $kernel->post(bot => privmsg => $channel, "$nick: There are many things I have seen. Perhaps you should ask for someone in particular?");
    } elsif(lc($person) eq lc($chosen_nick)) {
        $kernel->post(bot => ctcp => $channel, 'action', "waves $hisher hand in front of $hisher face. \"Yup, I can see myself!\"");
    } elsif($seenData{lc($person)}) {
        my ($when, $doing, $seenData) = split(/!/, $seenData{lc($person)}, 3);
        $doing = "saying \"$seenData\"" if($doing eq 'SAY');
        $doing = 'in a private message' if($doing eq 'PMSG');
        $doing = "($seenData)" if ($doing eq 'ACTION');
        if($doing eq 'KICKED') {
            my ($kicker,$reason) = split(/!/, $seenData, 2);
            $doing = "getting kicked by $kicker ($reason)";
        }
        if($doing eq 'KICKING') {
            my ($kicked,$reason) = split(/!/, $seenData, 2);
            $doing = "kicking $kicked ($reason)";
        }
        my $response = "I last saw $person " . timeago($when) . " ${doing}.";
        $kernel->post(bot => privmsg => $channel, "$nick: $response");
    } else {
        $kernel->post(bot => privmsg => $channel, "$nick: I have not seen $person.");
    }
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
 
# SET_SEEN: Updates seen data
sub set_seen {
    my($nick, $doing, $content) = @_;
    &debug(4, "Seeing $nick ($doing $content)\n");
    my $time = time;
    $seenData{lc($nick)} = "$time!$doing!$content";
    
    if($doing eq 'KICKED') {
        $doing = 'KICKING';
        my ($kicker, $reason) = split(/!/, $content, 2);
        $seenData{lc($kicker)} = "$time!$doing!$nick!$reason";
        &debug(4, "Seeing $kicker ($doing $nick!$reason)\n");
    }
}

# CLEANUP_SEEN: Cleans up when we're quitting
sub cleanup_seen {
    &debug(3, "Saving seen data\n");
    dbmclose(%seenData);
}
### END seen stuff

### BEGIN dice
$plugin{'%roll'} = "roll_dice";
$plugin_desc{'%roll'} = 'Rolls dice. You can specify how many dice, and how many sides, in the format 3D6.';
$plugin{'%flip'} = "flip_coin";
$plugin_desc{'%flip'} = 'Flips a coin.';

sub roll_dice {
    my $numDice = 2;
    my $numSides = 6;
    my ($nick, undef, $dice) = @_;
    if($dice =~ m/(\d*)[Dd](\d+)/) {
        $numDice = (defined $1 ? $1 : 1);
        $numSides = $2;
    }
    if($numDice == 0) {
        $kernel->post(bot => privmsg => $channel, "$nick: I can't roll zero dice!");
    } elsif($numDice > 100000000000000) {
        $kernel->post(bot => privmsg => $channel, "$nick: I can't even count that high!");
    } elsif($numDice > 100) {
        $kernel->post(bot => ctcp => $channel, 'ACTION', "drops $numDice ${numSides}-sided dice on the floor, trying to roll them for ${nick}.");
    } elsif($numSides == 0) {
        $kernel->post(bot => ctcp => $channel, 'ACTION', "rolls $numDice zero-sided " . (($numDice==1) ? 'die' : 'dice') . " for ${nick}: " . (($numDice==1) ? "it doesn't" : "they don't") . ' land, having no sides to land on.');
    } else {
        my @rolls = ();
        for(my $x=0;$x<$numDice;$x++) {
            push(@rolls, int rand($numSides)+1);
        }
    
        $kernel->post(bot => ctcp => $channel, 'ACTION', "rolls $numDice ${numSides}-sided " . (($numDice==1) ? 'die' : 'dice') . " for ${nick}: " . join(' ', @rolls));
    }
}

sub flip_coin {
    my $nick = $_[0];
    $kernel->post(bot => ctcp => $channel, 'ACTION', "flips a coin for $nick: "
        . ((int rand(2)==0) ? 'heads' : 'tails'));
}
### END dice

### BEGIN weather
# Weather needs Geo::METAR to be useable.
if (eval { require Geo::METAR; } && eval { require LWP::UserAgent; }) {
    $plugin{"%weather"} = "get_wx";
    $plugin_desc{"%weather"} = "Gets a weather report for the given station";
    debug(3, "Geo::METAR, LWP::UserAgent loaded: Weather plugin will be used\n");
} else {
    debug(3, "GEO::METAR, LWP::UserAgent failed: Weather plugin will not be available\n");
}

# GET_WX: Fetches a METAR report and gives a few weather conditions
sub get_wx {
    my ($nick, undef, $station) = @_;
    if(length($station) != 4) {
	# Whine and bail
	$kernel->post(bot => privmsg => $channel,
               "$nick: That doesn't look like a METAR station.");
	return;
    }
    $station = uc($station);
    #Fetch report from http://weather.noaa.gov/pub/data/observations/metar/stations/$station.TXT
    my $url = 'http://weather.noaa.gov/pub/data/observations/metar/stations/' 
        . $station . '.TXT';
    &debug(3, 'Received weather command from ' . $nick . 
	   " for $station\n");
    my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
    $useragent->agent("$project/1.0");
    $useragent->timeout(5);
    my $request = HTTP::Request->new(GET => $url);
    my $response = $useragent->request($request);
    if (!$response->is_error) {
	my (undef, $raw_metar) = split(/\n/, $response->content);
	my $m = new Geo::METAR;
	&debug(3, "METAR is " . $raw_metar . "\n");
	$m->metar($raw_metar);
        
	# Let's form a response!
        $m->{date_time} =~ m/\d\d(\d\d)(\d\d)Z/;
        my $time = "$1:$2";
	my $reply = "As reported at $time UTC at $station it is ";
	my @reply_with;
	$reply .= $m->TEMP_F . '°F (' . int($m->TEMP_C) . '°C) ' if defined $m->TEMP_F;
	if($m->WIND_MPH) {
	    my $tmp = $m->WIND_MPH . ' mph winds';
            $tmp .= ' from the ' . $m->WIND_DIR_ENG if defined $m->WIND_DIR_ENG;
	    push(@reply_with, $tmp);
	}

        push(@reply_with, @{$m->WEATHER});
        my @sky = @{$m->SKY};
# Geo::METAR returns sky conditions that can't be plugged into sentences nicely
# let's clean them up.
        for(my $x=0;$x<=$#sky;$x++) {
            $sky[$x] = lc($sky[$x]);
            $sky[$x] =~ s/solid overcast/overcast/;
            $sky[$x] =~ s/sky clear/clear skies/;
            
            $sky[$x] =~ s/(broken|few|scattered) at/\1 clouds at/;
        }
        
        push(@reply_with, @sky);

        $reply .= "with " . join(', ', @reply_with) if @reply_with;
        $reply .= '.';

	$kernel->post(bot => privmsg => $channel, "$nick: $reply");
    } else {
	$kernel->post(bot => privmsg => $channel, "$nick: Sorry, I could not access NOAA.");
    }
}
### END weather

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
-    $kernel->post(bot => ctcpreply => $nick, 'TIME ' . $reply);
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
	if ($plugin{$command[0]}) {
	    &{$plugin{$command[0]}}($nick, @command);
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
    &set_seen($nick, 'SAY', $text);
}

# PROCESS_ACTION: Handle actions sent to the channel.
sub process_action {
    my ($usermask, undef, $text) = @_[ ARG0, ARG1, ARG2 ];
    my ($nick) = split(/!/, $usermask);
    &debug(3, "Learning from " . $nick . "'s action...\n");
    &buildrecords($text,"ACTION");
    &set_seen($nick, 'ACTION', "$nick $text");
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
    
    &set_seen($nick, 'KICKED', "${kicker}!$reason");
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
