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
#   Copyright (C) 2004-05, Pete Pearson
#
#   This program is free software; you can redistribute and/or modify it
#   under the terms of version 2 of the GNU General Public License as
#   published by the Free Software Foundation.
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
#   * Figure out how the heck we should handle deletions when there are
#     multiple factoids
#   * Don't learn something we already know with 'is also'
#   * Find all the cases where the info plugin fails to respond, and
#     fix them
#

package SimBot::plugin::info;

use warnings;
use strict;

# Let's declare our globals.
use vars qw( %info );


use constant CMD_PREFIX => SimBot::option('global', 'command_prefix');
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

use constant BUT_X_IS_MANY => (
    '$nick: I already know many things about $key. Try \''
        . CMD_PREFIX
        . 'info list $key\' to show them.',
);

use constant X_IS_X => (
    '$nick: Wouldn\'t $key $isare $factoid be a truism?',
);

use constant X_IS_NOT_X => (
    '$nick: I don\'t know what reality you are residing in, but in mine $key $isare $factoid doesn\'t hold.',
    '$nick: Maybe in %bold%your%bold% universe $key $isare $factoid, but I beg to differ.',
);

use constant I_CANNOT => (    # used to respond to requests with bad words
    'I cannot do that, $nick.',
);

# these flags are used globally. Flags <= 128 are specific to the function
use constant BEING_ADDRESSED    => 256;

# these flags are used to tell handle_query stuff, also used when storing
# factoids
use constant PREFER_DESC        => 128;
use constant PREFER_LOCATION    => 64;
use constant NO_RECURSE         => 32;
#                               => 16;
#                               => 8;
#                               => 4;
#                               => 2;
#                               => 1;

# These flags are for factoids
use constant FACT_ARE           => 128;
use constant FACT_SEE_OTHER     => 64;
use constant FACT_URL           => 32;
use constant FACT_LOCKED        => 16;
 
sub messup_info {
    dbmopen(%info, 'info', 0664);
}

sub cleanup_info {
    dbmclose(%info);
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
    
	my $prefix = CMD_PREFIX;
    if($content =~ s/^${prefix}info +//o) {
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
        $person_being_referenced = &SimBot::option('global', 'nickname');
#    } elsif($person_being_addressed =~ m/$SimBot::nickname/g) {
#        $being_addressed = 1;
    }
    
    
    if($SimBot::snooze && !$being_addressed) {
        # SimBot's in snooze mode, and shouldn't learn and should avoid
        # talking. Since we aren't being addressed, let's remain quiet
        return;
    }
    
    # Let's expand all the pronouns in the chat so we can learn something
    # useful. Also, try to expand any lazy URLs.
    $content = &munge_pronouns($content, $nick, $person_being_referenced);
    $content = &normalize_urls($content);
    
    if($being_addressed && $content =~ m{^forget ([\'\-\w\s]+)}i) { #'
        # someone wants us to forget
        
        my($forgotten, $key) = (0, lc($1));
        if($info{$key}) {
            delete $info{$key};
            
            &SimBot::debug(4, "info: Forgot $key (req'd by $nick)\n");
            &SimBot::send_message($channel,
                &parse_message(&SimBot::pick(OK_FORGOTTEN),
                               $nick, $key));
        } else {
            &SimBot::send_message($channel,
                &parse_message(&SimBot::pick(CANT_FORGET),
                               $nick, $key));
        }
    } elsif($being_addressed && $content =~ m{^list ([\'\-\w\s]+)}i) {
        # someone wants to know all factoids for something '
        my $key = lc($1);
        
        if($info{$key}) {
            my @factoids = split(/\|\|/, $info{$key});
            my($factFlags, $factoid, $isare);
            my $response = "$nick: $key ";
            foreach (@factoids) {
                ($factFlags, $factoid) = split(/\|/);
                $isare = 'is';
                if($factFlags & FACT_ARE)   { $isare = 'are'; }
                elsif($factFlags & FACT_SEE_OTHER) { $isare = 'is aka'; }
                $response .= "$isare $factoid, ";
            }
            &SimBot::send_message($channel, $response);
        } else {
            &SimBot::send_message($channel,
            &parse_message(&SimBot::pick(I_DONT_KNOW),
                           $nick, $key));
        }
        
    } elsif($content =~ m{(where|what|who) (is|are) ([\'\-\w\s]+)}i) {
        # looks like a query '
        # if $1 is where, we should try to respond with a URL
        # otherwise, we should try to respond with a non-URL
        my $key = $3;
        my $flags;
        if($1 =~ m/where/i)     { $flags =  PREFER_LOCATION;    }
        else                    { $flags =  PREFER_DESC;        }
        if($being_addressed)    { $flags |= BEING_ADDRESSED;    }
        
        &handle_query($key, $nick, $channel, $person_being_referenced,
                      $flags);
    } elsif($content =~ m{where can (I|one) find ([\'\w\s]+)}i) {
        # looks like a query, try to respond with a location '
        &handle_query($2, $nick, $channel, $person_being_referenced,
                      ($being_addressed ? BEING_ADDRESSED : 0)
                      | PREFER_LOCATION);
    } elsif($content =~ m{([\'\-\w\s]+) is( also)?[\s\w]* (\w+://\S+)}i) {
        # looks like a URL to me!
        # let's try to learn it.
        my ($key, $also, $factoid) = (lc($1), $2, $3);
        
        my $flags = FACT_URL;
        if($being_addressed) { $flags |= BEING_ADDRESSED; }
        
        if($also) {
            # We are learning something *also*
            # add it to the existing key if any. If there isn't, well,
            # I guess 'also' didn't make sense but let's learn it anyway.
            if($info{$key}) { $info{$key} .= "||$flags|$factoid"; }
            else            { $info{$key} =    "$flags|$factoid"; }
            
            &report_learned($channel, $nick, $key, $factoid, $flags);
        } elsif($info{$key}) {
            # The key already exists, but the user didn't specify 'also'
            # We should whine if we are being addressed, and just ignore
            # it if we aren't.
            if($being_addressed) {
                if($info{$key} =~ m/\|\|/) {
                    # multiple keys
                    &SimBot::send_message($channel,
                        &parse_message(&SimBot::pick(BUT_X_IS_MANY),
                            $nick, $key));
                } else {
                    my ($keyFlags, $oldFactoid) = split(/\|/, $info{$key}, 2);
                    my ($isare);
                    
                    if   ($keyFlags & FACT_ARE)         { $isare = 'are';    }
                    elsif($keyFlags & FACT_SEE_OTHER)   { $isare = 'is aka'; }
                    else                                { $isare = 'is';     }
                
                    &SimBot::send_message($channel,
                        &parse_message(&SimBot::pick(BUT_X_IS_Y), $nick,
                                       $key, $isare, $oldFactoid));
                }
            }
        } else {
            $info{$key} = "$flags|$factoid";
            &report_learned($channel, $nick, $key, $factoid, $flags);
        }
    } elsif($content =~ m{([\'\w][\'\-\w\s]*?) (is|are) ((aka|also) )?(.*)}i) { #'
		no warnings;
        my ($key, $isare, $akaalso, $factoid) = (lc($1), $2, $4, $5);
        
        my $flags=0;
        if   ($akaalso =~ m/aka/i)  { $flags |= FACT_SEE_OTHER;     }
        if   ($isare =~ m/are/i)    { $flags |= FACT_ARE;           }
        if   ($being_addressed)     { $flags |= BEING_ADDRESSED;    }
        
        unless($being_addressed) {
            if($factoid =~ m/([\'\-\w\s]+)/) { #'
                $factoid = $1;
            } else {
                # We aren't being addressed, and the factoid
                # seems to have no data before punctuation
                # let's not learn it.
                return;
            }
        }
        
        # if the line contains something on simbot's block list, we
        # refuse to learn it. If we are being addressed, we give a
        # nondescript error message.
        foreach(&SimBot::option_list('filters')) {
            if($content =~ /$_/i) {
                &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(I_CANNOT), $nick))
                    if $being_addressed;
                return;
            }
        }
        
        if($key eq lc($factoid)) {
            &SimBot::send_message($channel,
                &parse_message(&SimBot::pick(X_IS_X), $nick, $key,
                $isare, $factoid)) if $being_addressed;
            return;
        }
        
        if($key =~ m/(your|you're|you are)/i) {
            # key contains a pronoun we can't expand
            # Let's not learn it.
            return;
        }

        if($akaalso =~ m/also/i) {
            # We are learning something *also*

            if($info{$key}) { $info{$key} .= "||$flags|$factoid"; }
            else            { $info{$key} =    "$flags|$factoid"; }
            
            &report_learned($channel, $nick, $key, $factoid, $flags);
        } elsif($info{$key} && $being_addressed) {
            if($info{$key} =~ m/\|\|/) {
                # multiple keys
                &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(BUT_X_IS_MANY),
                        $nick, $key));
            } else {
                my ($keyFlags, $oldFactoid) = split(/\|/, $info{$key}, 2);
                my ($isare);
                
                if   ($keyFlags & FACT_ARE)         { $isare = 'are';    }
                elsif($keyFlags & FACT_SEE_OTHER)   { $isare = 'is aka'; }
                else                                { $isare = 'is';     }
            
                &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(BUT_X_IS_Y), $nick,
                                   $key, $isare, $oldFactoid));
            }

        } elsif(!$info{$key}) {
            $info{$key} = "$flags|$factoid";
            &report_learned($channel, $nick, $key, $factoid, $flags);
        }
    } elsif($being_addressed && $content =~ m{^([\'\-\w\s]+)$}) {
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
#   $flags:     bit flags PREFER_LOCATION, PREFER_DESC, and BEING_ADDRESSED
# Returns:
#   nothing
sub handle_query {
    my ($query, $nick, $channel, $addressed, $flags) = @_;
        
    if($addressed && !($flags & BEING_ADDRESSED)) {
        # Someone's being referenced, and it isn't us.
        # We should keep quiet.
        return;
    }
    
    $query = lc($query);
    if($info{$query}) {
        my @factoids = split(/\|\|/, $info{$query});
        my($factFlags, $factoid);
        
        # If we are to prefer locations or descriptions, let's remove
        # everything else from the list.
        if(($flags & PREFER_LOCATION) || ($flags & PREFER_DESC)) {
            for(my $i=0;$i<=$#factoids;$i++) {
                ($factFlags,$factoid) = split(/\|/, $factoids[$i], 2);
                my $isLoc = 0;
                if(($factFlags & FACT_URL)
                   || ($factoid =~ m/^(at|on|in|near)/i)) {
                    $isLoc = 1;
                }
                if(  ($flags & PREFER_LOCATION  && !$isLoc)
                  || ($flags & PREFER_DESC      && $isLoc) ) {
                    # if we are preferring URLs, and the factoid isn't
                    # or we are preferring non-URLs, and the factoid is
                    
                    splice(@factoids, $i, 1); # remove it
					$i--;
                }
			}
            # if we lost all of the factoids, let's get the list back
            if(!@factoids) { @factoids = split(/\|\|/, $info{$query}); }
        }
        
        ($factFlags, $factoid) = split(/\|/, &SimBot::pick(@factoids), 2);
        
        my $isare = 'is';
        if($factFlags & FACT_ARE)   { $isare = 'are'; }
        
        if($factFlags & FACT_SEE_OTHER
           && !($flags & NO_RECURSE)) {
            &handle_query($factoid, $nick, $channel, undef,
                          $flags | NO_RECURSE);
            return;
        }
        
        if($factFlags & FACT_URL)   { $factoid = "at ${factoid}"; }
        
        &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(QUERY_RESPONSE),
                                   $nick, $query, $isare, $factoid));
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
#   $factoid:   the factoid that was learned
#   $flags:     FACT_ARE, FACT_URL, FACT_SEE_OTHER, BEING_ADDRESSED
# Returns:
#   nothing
sub report_learned {
    my($channel, $nick, $key, $factoid, $flags) = @_;
    my $flagTxt;
    
    if   ($flags & FACT_ARE)        { $flagTxt =  '=are=>';         }
    elsif($flags & FACT_SEE_OTHER)  { $flagTxt =  '=seeother=>';    }
    else                            { $flagTxt =  '=is=>';          }
    if   ($flags & FACT_URL)        { $flagTxt .= ' =url=';         }
    
    &SimBot::debug(4, "info: Learning from $nick: $key $flagTxt $factoid\n");
    &SimBot::send_message($channel,
        &parse_message(&SimBot::pick(OK_LEARNED), $nick)
        . " ($key $flagTxt $factoid)")
        if ($flags & BEING_ADDRESSED);
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
    
    $message =~ s/\$nick/$nick/g;
    $message =~ s/\$key/$key/g;
    $message =~ s/\$isare/$isare/g;
    $message =~ s/\$factoid/$factoid/g;
    
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
    
    $content =~ s{\bi am\b} {$nick is}ig;   # I am -> $nick is
    $content =~ s{\bmy\b}   {${nick}'s}ig;  # my   -> $nick's
    $content =~ s{\bmine\b} {${nick}'s}ig;  # mine -> $nick's
    $content =~ s{\bme\b}   {$nick}ig;      # me   -> $nick
    $content =~ s{\bam i\b} {is $nick}ig;   # am I -> is $nick
    if($person_being_referenced) {
        # you're, you are   -> $person_being_referenced is
        $content =~ s/\b(you\'re|you are)/${person_being_referenced} is/ig;
        #'
        # your              -> $person_being_referenced's
        $content =~ s/\byour/${person_being_referenced}\'s/ig; #'
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
            if($host =~ m{\.(com|org|net|edu|gov|mil|int
                            |biz|pro|info|aero|coop|name
                            |museum|\w\w)$}ix) {
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
    plugin_params => '(<key> [is [also] <fact>] | list <key> | forget <key>)',
    plugin_help     => <<EOT,
If only <key> is specified, a random associated fact will be returned.
If <key> is <fact> is specified, <fact> will be stored under <key>, unless
  <key> already exists. Use 'is also' to add facts to existing keys.
If list <key> is specified, all associated facts will be returned.
If forget <key> is specified, all associated facts will be deleted.
The truthfulness of any stored facts is not guaranteed.
EOT

    event_plugin_call   => sub {}, # Do nothing.
    event_plugin_load   => \&messup_info,
    event_plugin_unload => \&cleanup_info,
    event_channel_message   => \&handle_chat,
);
