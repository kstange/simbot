###
#  SimBot Info Plugin
#
# DESCRIPTION:
#   The Info plugin is designed to bring Infobot style features to
#   SimBot. It'll learn things (factoids) from the channel, usually in
#   the form of "x is y". Later, when someone asks for it using
#   '%info x', SimBot will respond with what it knows about x. It will
#   even respond to "What is x?" type questions if it believes the
#   question wasn't asked of anyone in particular.
#
# COPYRIGHT:
#   Copyright (C) 2004, Pete Pearson
#
#   This program is free software; you can redistribute it and/or modify
#   under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#   
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#   
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
# TODO:
#   * We need a far more intelligent way to figure out where exactly the
#     factoid ends or the key begins.
#   * Ditch the stupid separate is and are databases.
#   * Support for multiple factoids on a key.
#      - format will probably be flags|factoid||flags|factoid...
#      - flags will remember if it is IS or ARE, and if it is a URL or not
#        and perhaps other statuses like locked.
#   * Figure out how the heck we should handle deletions when there are
#     multiple factoids
#

package SimBot::plugin::info;

use warnings;
use strict;

# Let's declare our globals.
use vars qw( %isDB %areDB );

# These constants define the phrases simbot will use when responding
# to queries.
use constant I_DONT_KNOW => (
    '$nick: Damned if I know!',
    '$nick: Huh?',
    'I dunno, $nick.',
    'Tell me if you find out, $nick.',
);

use constant OK_LEARNED => (
    '$nick: I will remember that.',
    'OK, $nick.',
    'I\'ll keep that in mind, $nick.',
);

use constant OK_FORGOTTEN => (
    '$nick: What were we talking about again?',
	'$nick: Information has been nullified!  Have a nice day.',
	'$nick: Done.  Wouldn\'t it be cool if %uline%you%uline% could forget on demand?',
);
use constant CANT_FORGET => (
    '$nick: I don\'t know anything about $key.'
);

use constant QUERY_RESPONSE => (
    '$nick: I have been told that $key $isare $factoid.',
    '$nick: Someone mentioned that $key $isare $factoid.',
    '$nick: $key, according to popular belief, $isare $factoid.',
);

use constant ALREADY_WAS => (
    'I already know that, $nick.',
    '$nick: You\'re telling me stuff I already know!',
);

use constant BUT_X_IS_Y => (
    '$nick: I thought $key $isare $factoid.',
);

use constant I_CANNOT => (    # used to respond to requests with bad words
    'I cannot do that, $nick.',
);

# these flags are used to tell handle_query stuff, also used when storing
# factoids
use constant PREFER_URL         => 128;
use constant PREFER_DESC        => 64;
use constant BEING_ADDRESSED    => 32;
#                               => 16;
#                               => 8;
#                               => 4;
#                               => 2;
#                               => 1;
 
sub messup_info {
    dbmopen(%isDB, 'is', 0664);
    dbmopen(%areDB, 'are', 0664);
}

sub cleanup_info {
    dbmclose(%isDB); dbmclose(%areDB);
}

### handle_chat
# This method parses all messages said in the channel for things that
# appear to be queries or factoids and responds to and/or learns them
#
# Arugments:
#   undef
#   $nick:      nickname of the person speaking
#   $channel:   channel the chat was in
#   undef
#   $content:   content of the message
# Returns:
#   nothing
sub handle_chat {
    my(undef, $nick, $channel, undef, $content) = @_;
    my($person_being_referenced, $being_addressed, $is_query); 
    
    if($content =~ s/^.info ?//) {
        $being_addressed = 1;
    }
    
    # Is someone being referenced?
    if($content =~ s{, (\S*)[.\!\?]?$}{}) { # whatever, JohnDoe
        $person_being_referenced = $1;
    }
    if($content =~ s{^(\S*)[:,] }{}) {      # JohnDoe: whatever
        $person_being_referenced = $1;
    }
    if($being_addressed) {
        $person_being_referenced = $SimBot::nickname;
#    } elsif($person_being_addressed =~ m/$SimBot::nickname/g) {
#        $being_addressed = 1;
    }
    
    $content = &munge_pronouns($content, $nick, $person_being_referenced);
    $content = &normalize_urls($content);
    
    if($being_addressed && $content =~ m{^forget ([\w\s]+)}i) {
        # someone wants us to forget
        
        my($forgotten, $key) = (0, lc($1));
        if($isDB{$key}) {
            delete $isDB{$key};
            $forgotten = 1;
        }
        if($areDB{$key}) {
            delete $areDB{$key};
            $forgotten = 1;
        }
        if($forgotten) {
            &SimBot::debug(3, "Forgot $key (req'd by $nick)\n");
            &SimBot::send_message($channel,
                &parse_message(&SimBot::pick(OK_FORGOTTEN),
                               $nick, $key));
        } else {
            &SimBot::send_message($channel,
                &parse_message(&SimBot::pick(CANT_FORGET),
                               $nick, $key));
        }
    } elsif($content =~ m{(where|what|who) is ([\'\w\s]+)}i) {
        # looks like a query
        # if $1 is where, we should try to respond with a URL
        # otherwise, we should try to respond with a non-URL
        my $key = $2;
        my $flags;
        if($1 =~ m/where/i) { $flags =  PREFER_URL;         }
        else                { $flags =  PREFER_DESC;        }
        if($being_addressed){ $flags |= BEING_ADDRESSED;    }
        
        &handle_query($key, $nick, $channel, $person_being_referenced,
                      $flags);
    } elsif($content =~ m{where can (I|one) find ([\'\w\s]+)}i) {
        # looks like a query, try to respond with a URL
        &handle_query($2, $nick, $channel, $person_being_referenced,
                      ($being_addressed ? BEING_ADDRESSED : 0)
                      | PREFER_URL);
    } elsif($content =~ m{([\'\w\s]+) is[\s\w]* (\w+://\S+)}i) {
        # looks like a URL to me!
        my ($key, $factoid) = (lc($1), $2);
        $factoid = 'at ' . $factoid;
        unless($isDB{$key}) {
            $isDB{$key} = $factoid;
            &report_learned($channel, $nick, $key, 'is', $factoid,
                            $being_addressed);
        }
    } elsif($content =~ m{([\'\w\s]+?) (is|are) ([\'\w\s]+)}i) {
        my ($key, $isare, $factoid) = (lc($1), $2, $3);

        foreach(@SimBot::chat_ignore) {
            if($content =~ /$_/) {
                &SimBot::send_message($channel, 
                    &parse_message(&SimBot::pick(I_CANNOT), $nick))
                    if $being_addressed;
                return;
            }
        }
        
        if($key =~ m/(your|you're|you are)/i) {
            # key contains a pronoun we can't expand
            # Let's not learn it.
            return;
        }
        if($isare =~ m/is/i) {
            if($isDB{$key}) {
                &SimBot::send_message($channel, 
                    &parse_message(&SimBot::pick(BUT_X_IS_Y), $nick,
                                   $key, 'is', $isDB{$key}))
                    if $being_addressed;
            } else {
                $isDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'is', $factoid,
                                $being_addressed);
            }
        } else {
            if($areDB{$key}) {
                &SimBot::send_message($channel, 
                    &parse_message(&SimBot::pick(BUT_X_IS_Y), $nick,
                                   $key, 'are', $areDB{$key}))
                    if $being_addressed;
            } else {
                $areDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'are', $factoid,
                                $being_addressed);
            }
        }
    } elsif($being_addressed && $content =~ m{^([\'\w\s]+)$}) {
        # KEEP THIS ELSIF LAST
        # Single phrase, doesn't match anything else and we are being
        # addressed. Let's do a query.
        &handle_query($1, $nick, $channel, undef, BEING_ADDRESSED);
    }
}

### handle_query
# This method takes a query and sends back to the channel the response
#
# Arguments:
#   $query:     the key we are looking up
#   $channel:   channel the chat was in
#   $addressed: content of the message
#   $flags:     bit flags PREFER_URL, PREFER_DESC, and BEING_ADDRESSED
# Returns:
#   nothing
sub handle_query {
    my ($query, $nick, $channel, $addressed, $flags) = @_;
    warn "$nick $query $flags $addressed";
    
    if($addressed && !($flags & BEING_ADDRESSED)) {
        # Someone's being referenced, and it isn't us.
        # We should keep quiet.
        # FIXME: This really should be elsewhere...
        return;
    }
    
    $query = lc($query);
    if($isDB{$query}) {
        &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(QUERY_RESPONSE),
                                   $nick, $query, 'is', $isDB{$query}));
    } elsif($areDB{$query}) {
        &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(QUERY_RESPONSE),
                                   $nick, $query, 'are', $areDB{$query}));
    } elsif($flags & BEING_ADDRESSED) {
        # we're being addressed, but don't have an answer...
        &SimBot::send_message($channel,
            &parse_message(&SimBot::pick(I_DONT_KNOW),
                           $nick, $query));
    }
}

### report_learned
# This method simply logs and reports to the channel that some fact
# has been learned.
#
# Arguments:
#   $channel:   channel the chat was in
#   $nick:      nickname of the person speaking
#   $key:       the key that was learned
#   $isare:     'is' or 'are'
#   $factoid:   the factoid that was learned
#   $addressed: were we addressed with %info?
# Returns:
#   nothing
sub report_learned {
    my($channel, $nick, $key, $isare, $factoid, $addressed) = @_;
    &SimBot::debug(3, "Learning from $nick: $key =$isare=> $factoid\n");
    &SimBot::send_message($channel,
        &parse_message(&SimBot::pick(OK_LEARNED), $nick)
        . " ($key =$isare=> $factoid)")
        if $addressed;
}

### parse_message
# This function parses a string for certain variables, as well as for
# style tags. Used for all the messages sent to the channel.
#
# Arguments:
#   $message:   the string we are working on
#   $nick:      the nickname we are speaking to
#   $key:       the key of the factoid that was learned, or undef
#   $isare:     'is', 'are', or undef
#   $factoid:   the factoid that was learned, or undef
# Returns:
#   a string containing IRC color codes and completed variables
#   this string <strong>should not</strong> be output to a console!
sub parse_message {
    my ($message, $nick, $key, $isare, $factoid) = @_;
    
    $message = &SimBot::parse_style($message);
    
    $message =~ s/\$nick/$nick/;
    $message =~ s/\$key/$key/;
    $message =~ s/\$isare/$isare/;
    $message =~ s/\$factoid/$factoid/;
    
    return $message;
}

### munge_pronouns
# This function looks through a string for pronouns (I, my, you're, your)
# and expands them to the actual person (if known).
#
# Arguments:
#   $content:   the string we are working on
#   $nick:      the nickname that is speaking
#   $person_being_referenced:   the person $nick is speaking to or undef
#   $thirdperson: is $nick speaking in the third person? (IRC action?)
# Returns:
#   a string with expanded pronouns
sub munge_pronouns {
    my ($content, $nick, $person_being_referenced, $thirdperson) = @_;
    
    $content =~ s/(^|\s)i am /$1$nick is /ig;
    $content =~ s/(^|\s)my /$1${nick}'s /ig;
    if($person_being_referenced) {
        $content =~ s/(^|\s)(you're|you are) /$1${person_being_referenced} is /ig;
        $content =~ s/(^|\s)your /$1${person_being_referenced}\'s /ig;
    }
    
    return $content;
}

### normalize_urls
# This function looks through a string for things that might be URLs and
# turns them into actual URLs.
#
# Arguments:
#   $_[0]: The string we are working on
# Returns:
#   a string with expanded URLs
sub normalize_urls {
    my @words = split(/\s+/, $_[0]);
    my $curWord;
        
    foreach $curWord (@words) {
        # map some common host names to protocols
        $curWord =~ s{^(www|web)\.} {http://$1\.};
        $curWord =~ s{^ftp\.}       {ftp://ftp\.};
        
        if($curWord =~ m{^((http|ftp|news|nntp|mailto|aim)s?:[\w.?/]+)}) {
            $curWord = $1;
            next;
        }
        
        if($curWord =~ m{/}) {
            my ($host, $path) = split(m{/}, $curWord, 2);
            
            # does the first segment have a TLD?
            if($host =~ m{\.(com|org|net|int|mil|gov|edu|biz|pro|info|aero|coop|name|museum|\w\w)$}g) {
                # Yup. Let's assume it's a web site...
                $host = 'http://' . $host;
            }
            $curWord = $host . '/' . $path;
        }
    }
    return join(' ', @words);
}

&SimBot::plugin_register(
    plugin_id   => 'info',
    plugin_desc => 'Tells you what simbot has learned about something.',
    event_plugin_call   => sub {}, # Do nothing.
    event_plugin_load   => \&messup_info,
    event_plugin_unload => \&cleanup_info,
    event_channel_message   => \&handle_chat,
);
