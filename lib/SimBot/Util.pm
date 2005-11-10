#!/usr/bin/perl

# SimBot::Util
#
# Copyright (C) 2002-05, Kevin M Stange <kevin@simguy.net>
#
# This program is free software; you can redistribute and/or modify it
# under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
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

# Hi, my name(space) is:
package SimBot::Util;

# Exports
use Exporter 'import';
@EXPORT = qw(
			 VERSION PROJECT HOME_PAGE DEBUG_NO_PREFIX
			 DEBUG_NONE DEBUG_ERR DEBUG_WARN DEBUG_STD DEBUG_INFO DEBUG_SPAM
			 debug load_config pick option option_list options_in_section
			 pick get_args parse_style htmlize html_mask_email numberize
			 timeago char_sub
			 );

# To make our own character substitutions easier to read, let's
# be able to use character names
use charnames ':full';

use strict;
use warnings;

use vars qw (
			 %args %conf $color @named_colors
			 %numbers_groups %numbers_tens %numbers_digits %numbers_other
			 );

# Support for Terminal Colors
$color = eval {
	use Term::ANSIColor;
	$Term::ANSIColor::AUTORESET = 1;
};

# Software Name
use constant PROJECT => "SimBot";
# Software Version
use constant VERSION => "1.0 alpha";
# Software Home
use constant HOME_PAGE => 'http://simbot.sf.net/';

# Debug Constants
use constant DEBUG_PREFIX
	=> ('', 'ERROR: ', 'ALERT: ', '', 'DEBUG: ', 'SPAM: ');

use constant DEBUG_NONE => 0;
use constant DEBUG_ERR  => 1;
use constant DEBUG_WARN => 2;
use constant DEBUG_STD  => 3;
use constant DEBUG_INFO => 4;
use constant DEBUG_SPAM => 5;

use constant DEBUG_NO_PREFIX => 0x001;

use constant DEBUG_COLORS
	=> ("bold green", "bold red", "red", "", "bold blue", "blue");

# Default verbosity level
# 0 is silent, 1 shows errors, 2 shows alert, 3 shows normal information,
# 4 shows debug information, and 5 everything you never wanted to see.
use constant VERBOSE => 3;

# Number data for the numberize function
%numbers_groups = (
				   trillion => 1000000000000, billion       => 1000000000,
				   million  => 1000000,       thousand      => 1000,
				   hundred  => 100,           "hundred and" => 100,
				   );

%numbers_tens   = (
				   twenty => 20, thirty => 30,  forty => 40,  fifty => 50,
				   sixty => 60,  seventy => 70, eighty => 80, ninety => 90,
				   );

%numbers_other  = (
				   zero => 0,          a => 1,            ten => 10,
				   eleven => 11,       twelve => 12,      thirteen => 13,
				   fourteen => 14,     fifteen => 15,     sixteen => 16,
				   seventeen => 17,    eighteen => 18,    nineteen => 19,
				   );

%numbers_digits = (
				   one => 1, two => 2,   three => 3, four => 4, five => 5,
				   six => 6, seven => 7, eight => 8, nine => 9,
				   );


@named_colors = ("white", "black", "navy", "green", "red", "maroon",
				 "purple", "orange", "yellow", "lightgreen", "teal",
				 "cyan", "blue", "magenta", "gray", "silver");

## debug ( level, message, flags ); returns ( );
#
# Print out messages with the desired verbosity.
#
sub debug {
	if ((!defined $args{debug} && $_[0] <= VERBOSE) ||
		(defined $args{debug} && $_[0] <= $args{debug})) {
		my $bitmask = (defined $_[2] ? $_[2] : 0x000);
		my $prefix = ($bitmask & DEBUG_NO_PREFIX ? "" : (DEBUG_PREFIX)[$_[0]]);
		if ($_[0] != 3 && $_[0] != 0) {
			if ($color) {
				print STDERR colored ($prefix . $_[1], (DEBUG_COLORS)[$_[0]]);
			} else {
				print STDERR ($prefix . $_[1]);
			}
		} else {
			if ($color) {
				print STDOUT colored ($prefix . $_[1], (DEBUG_COLORS)[$_[0]]);
			} else {
				print STDOUT ($prefix . $_[1]);
			}
		}
	}
}

## pick ( array ); returns ( scalar );
#
# Picks a random item from an array and returns it.
#
sub pick {
    return $_[int(rand()*@_)];
}

## parse_args ( ); returns ( );
#
# Parses the arguments passed to the script. This is a private function.
#
sub parse_args {
	foreach (@ARGV) {
		if (m/^--/) {
			my ($flag, $value) = split(/=/);
			$flag =~ s/^--//;
			$value = 1 if (!defined $value);
			$args{$flag} = $value;
		} elsif (m/^-/) {
			my (@params) = split(//);
			foreach (@params) {
				$args{$_} = 1 unless $_ eq "-";
			}
		}
	}
}

## get_args ( ); returns ( hash table );
#
# Returns the arguments that were passed to the script in the forum of a hash
# table.
#
sub get_args {
	&parse_args if !defined %args;
	return %args;
}

## load_config ( filename ); returns ( );
#
# Loads in the specified configuration file.  If any configuration data is
# currently loaded, it will be deleted and replaced.
#
sub load_config {
	if (defined %conf) {
		debug(DEBUG_STD, "Reloading configuration file $_[0]...\n");
	} else {
		debug(DEBUG_STD, "Loading configuration file $_[0]...\n");
	}
	if (open(CONFIG, $_[0])) {
		undef %conf if defined %conf;
		my $section;
		foreach (<CONFIG>) {
			chomp;
			if (m/^#|^\s*$/) {
			} elsif (m/^\[(.*)\]$/) {
				&debug(DEBUG_SPAM, "Begin config section $1.\n");
				$section = $1;
			} elsif (m/^(.*?)=(.*)$/) {
				if ($section eq "filters") {
					if ($1 eq "match") {
						push(@{$conf{'filters'}}, qr/$2/i);
						&debug(DEBUG_SPAM, "$section: loaded match filter for $2\n");
					} elsif ($1 eq "word") {
						push(@{$conf{'filters'}}, qr/(^|\b)\Q$2\E(\b|$)/i);
						 &debug(DEBUG_SPAM, "$section: loaded word filter for $2\n");
					} else {
						&debug(DEBUG_SPAM, "$section: saw unknown filter type $1\n");
					}
				} else {
					push(@{$conf{$section}{$1}}, "$2");
					&debug(DEBUG_SPAM, "$section: loaded option $1 as $2\n");
				}
			}
		}
		undef $section;
		close(CONFIG);

		# Set sane defaults for options that might have been omitted
		if (!option('global', 'command_prefix')) {
			$conf{'global'}{'command_prefix'}[0] = '%';
			&debug(DEBUG_WARN, "global/command_prefix missing from config. Using '%'.\n");
		}
		if (!defined option('chat', 'new_sentence_chance')) {
			$conf{'chat'}{'new_sentence_chance'}[0] = 0;
			&debug(DEBUG_WARN, "chat/new_sentence_chance missing from config. Using 0 (off).\n");
		}
		if (!defined option('chat', 'delete_usage_max')) {
			$conf{'chat'}{'delete_usage_max'}[0] = -1;
			&debug(DEBUG_WARN, "chat/delete_usage_max missing from config. Using -1 (off).\n");
		}
		if (!option('network', 'username')) {
			$conf{'network'}{'username'}[0] = 'nobody';
			&debug(DEBUG_WARN, "network/username missing from config. Using 'nobody'.\n");
		}

		&debug(DEBUG_STD, "Configuration file loaded successfully!\n");

	} else {
		&debug(DEBUG_ERR, "Your configuration file ($_[0]) is missing or unreadable.\nMake sure you copied and customized the config.default.ini");
		die "Unable to continue without a configuration file" if !defined %conf;
	}
}

## option ( section, option ); returns ( value );
#
# Returns the value (or a random value from a list) for a particular option.
#
sub option {
	if (!defined %conf) {
		debug(DEBUG_WARN, "Configuration is not loaded!\n");
	}
	my ($sec, $val) = @_;
	return "" if (!defined $conf{$sec} || !defined $conf{$sec}{$val});
	return pick(@{$conf{$sec}{$val}});
}

## option_list ( section, option); returns ( array );
#
# Returns a list of the values set for a particular option.
#
sub option_list {
	if (!defined %conf) {
		debug(DEBUG_WARN, "Configuration is not loaded!\n");
	}
	my ($sec, $val) = @_;
	return () if !defined $conf{$sec};
	if ($sec eq "filters") {
		return @{$conf{$sec}};
	} else {
		return () if (!defined $conf{$sec}{$val});
		return @{$conf{$sec}{$val}};
	}
}

## options_in_section ( section ); returns ( array );
#
# Returns a list of the options that are set in a particular section.
#
sub options_in_section {
	if (!defined %conf) {
		debug(DEBUG_WARN, "Configuration is not loaded!\n");
	}
    my ($sec) = $_[0];
    return () if !defined $conf{$sec};
    return keys %{$conf{$sec}};
}

## parse_style ( string ); returns ( new string );
#
# Parses a string for style codes and turns them into IRC style codes.
#
sub parse_style {
    $_ = $_[0];
    # \003 begins a color. Avoid using black and white, as the window
    # will likely be either white or black, and you don't know which

    s/%white%/\0030/g;           # white
    s/%black%/\0031/g;           # black
    s/%navy%/\0032/g;            # navy
    s/%green%/\0033/g;           # green
    s/%red%/\0034/g;             # red
    s/%maroon%/\0035/g;          # maroon
    s/%purple%/\0036/g;          # purple
    s/%orange%/\0037/g;          # orange
    s/%yellow%/\0038/g;          # yellow
    s/%l(igh)?tgreen%/\0039/g;   # light green (ltgreen, lightgreen)
    s/%teal%/\00310/g;           # teal
    s/%cyan%/\00311/g;           # cyan
    s/%blue%/\00312/g;           # blue
    s/%magenta%/\00313/g;        # magenta
    s/%gray%/\00314/g;           # gray
    s/%silver%/\00315/g;         # silver

    s/%normal%/\017/g;           # normal - remove color and style

    s/%bold%/\002/g;             # bold
    s/%u(nder)?line%/\037/g;     # underline (uline)


    return $_;
}

## htmlize ( string ); returns ( new string );
#
# Converts IRC color codes and links into HTML text.
#
sub htmlize {
	my @lines = split(/\n/, $_[0]);
	my $string = "";
	foreach my $line (@lines) {
		my $bold = 0;
		my $reverse = 0;
		my $underline = 0;
		my $color = -1;
		my $bgcolor = -1;
		my $tag = "";
		$line =~ s/&/&amp;/;
		$line =~ s/>/&gt;/;
		$line =~ s/</&lt;/;
		$line = "<div>" . $line;
		while($line =~ m/[\002\003\017\026\037]+/) {
			my $block = $&;
			my @codes = split(//, $block);
			debug (DEBUG_SPAM, "htmlize: codes: " . (@codes) . "\n");
			foreach my $code (@codes) {
				if ($code eq "\002") {
					$bold = 1 - $bold;
					debug (DEBUG_SPAM, "htmlize: bold: $bold\n");
				} elsif ($code eq "\037") {
					$underline = 1 - $underline;
					debug (DEBUG_SPAM, "htmlize: underline: $underline\n");
				} elsif ($code eq "\026") {
					$reverse = 1 - $reverse;
					debug (DEBUG_SPAM, "htmlize: reverse: $reverse\n");
				} elsif ($code eq "\003") {
					$line =~ m/\003(\d{1,2})?(,(\d{1,2}))?/;
					if ($2) {
						$color = $1 if $1;
						$bgcolor = $3;
						$line =~ s/\003$1$2/\003/;
					} elsif ($1) {
						$color = $1;
						$line =~ s/\003$1/\003/;
					} else {
						$color = -1;
						$bgcolor = -1;
					}
					debug (DEBUG_SPAM, "htmlize: c: $color; bgc: $bgcolor\n");
				} else {
					$bold = 0;
					$underline = 0;
					$reverse = 0;
					$color = -1;
					$bgcolor = -1;
					debug (DEBUG_SPAM, "htmlize: b: $bold; u: $underline; r $reverse; c: $color; bgc: $bgcolor\n");
				}
			} #end foreach code
			debug (DEBUG_SPAM, "htmlize: old tag: $tag\n");
			if ($tag =~ /<span style=.*>/) {
				$tag = "</span>";
			} else {
				$tag = "";
			}
			my $css = ($bold      ? "font-weight: bold; " : "")
				. ($underline     ? "text-decoration: underline; " : "")
				. ($reverse       ? "color: white; background: black; "
				   : ($color != -1   ? "color: $named_colors[$color]; " : "")
				   . ($bgcolor != -1 ? "background: $named_colors[$bgcolor]; " : "")
				   );
			debug (DEBUG_SPAM, "htmlize: css: $css\n");
			$tag .= "<span style=\"$css\">" if ($css ne "");
			debug (DEBUG_SPAM, "htmlize: new tag: $tag\n");
			$line =~ s/$block/$tag/;
		} # end while blocks
		$line .= "</span>" if ($tag =~ /<span style=.*>/);
		$string .= $line . "</div>\n";
	} # end foreach lines
	$string =~ s%(http|ftp)://[^\s\n<>]+%<a href="$&">$&</a>%g;
    while($string =~ m/\b(\S+@[a-z\-\.]+\.[a-z]+)/i) {
	   my $email = $&;
	   my $masked = &html_mask_email($email);
	   $string =~ s/$email/$masked/g;
    }
	return $string;
}

## html_mask_email ( email address ); returns ( masked html );
#
# Returns the HTML for a masked email address.  Currently, we break the
# address apart into user and host, turn each character into its HTML
# escaped ascii code, and return a simple javascript with the address
# broken up and out of order. When run, the script outputs the address
# properly (and properly linked).
#
# This doesn't make harvesting impossible, but it does make it more
# difficult. Viewers without javascript see [email removed] instead.
#
sub html_mask_email {
    my ($user, $host) = $_[0] =~ m/^(\S+)@(\S+)$/;
    my ($nuser, $nhost);
    for(my $i = 0; $i < length $user; $i++) {
        $nuser .= '&#' . ord(substr($user, $i, 1)) . ';';
    }
    for(my $i = 0; $i < length $host; $i++) {
        $nhost .= '&#' . ord(substr($host, $i, 1)) . ';';
    }

    return <<EOT;
<script type="text/javascript">
var p='$nhost';
var w='&#116;&#111;&#58;';
var l='$nuser';
var u='&#109;&#97;';
var s='&#64;';
var d='&#105;&#108';
document.write('<a href="');
document.write(u+d);
document.write(w+l);
document.write(s+p);
document.write('">');
document.write(l);
document.write(s+p);
document.write('</a>');
</script><noscript>[email removed]</noscript>
EOT

}


## numberize ( string ); returns ( new string );
#
# Finds all the word-based numbers in a string and replaces them with
# digit-based numbers.
#
sub numberize {
	my $string = $_[0];
	debug(DEBUG_SPAM, "numberize: new string: $string\n");
	my $tmatch = "(" . join("|", keys(%numbers_tens)) . ")";
	my $omatch = "(" . join("|", keys(%numbers_other)) . ")";
	my $dmatch = "(" . join("|", keys(%numbers_digits)) . ")";
	while ($string =~ /\b($tmatch[-]$dmatch)\b/) {
		my $match = $1;
		my $value = ($numbers_tens{$2} + $numbers_digits{$3});
		$string  =~ s/$match/$value/g;
		debug(DEBUG_SPAM, "numberize: tens-ones: $string\n");
	}
	while ($string =~ /\b($tmatch|$omatch|$dmatch)\b/) {
		my $match = $1;
		my $value = (defined $numbers_tens{$match} ? $numbers_tens{$match} :
					 (defined $numbers_other{$match} ? $numbers_other{$match} :
					  $numbers_digits{$match}));
		$string  =~ s/$match/$value/g;
		debug(DEBUG_SPAM, "numberize: numbers: $string\n");
	}

	foreach my $match ("hundred and", "hundred", "thousand", "million", "billion", "trillion") {
		while ($string =~ /\b$match\b/) {
			my $value = $numbers_groups{$match};
			my $left  = "$`";
			my $right = "$'";
			if ($left  =~ s/([\s-]*)([0-9]+)\s*$/$1/) {
				$value *= $2 if $2;
			}
			if($right =~ s/^\s*([0-9]+)([\s-]*)/$2/) {
				$value += $1;
			}
			$string = "$left$value$right";
			debug(DEBUG_SPAM, "numberize: groups: $string\n");
		}
	}

	debug(DEBUG_SPAM, "numberize: final: $string\n");
	return $string;
}

## timeago ( unix time, specificity ); returns ( string );
#
# Returns a string of how long ago something happened.
# specificity:
#   0 shows as needed   (1 hour 15 minutes 36 seconds)
#   1 hides seconds     (1 hour 15 minutes)
#     except if there are only seconds
#
sub timeago {
    my ($seconds, $minutes, $hours, $days, $weeks, $years);
    my $now = time;

    $seconds = $now - $_[0];
    my $hidemode = (defined $_[1] ? $_[1] : 0);

    if($_[0] > $now) {
        &debug(DEBUG_WARN, "Trying to use timeago on a time in the future! Now is ${now}, Then is $_[0]\n");
    }
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
    push(@reply, "$seconds second" . (($seconds == 1) ? '' : 's'))
        if $seconds && $hidemode != 1;
    if(@reply) {
		my $string = join(', ', @reply) . ' ago';
		$string =~ s/(.*),/$1 and/;
		return $string;
	} else {
		return 'very recently';
    }
}

## char_sub ( string ); returns ( new string );
#
# Returns the string with some odd unicode replaced with more ordinary
# characters.
#
sub char_sub {
    my $text = $_[0];

    $text =~ s/\N{HORIZONTAL ELLIPSIS}/.../g;
    $text =~ s/\N{TWO DOT LEADER}/../g;
    $text =~ s/\N{ONE DOT LEADER}/./g;
    $text =~ s/\N{DOUBLE QUESTION MARK}/??/g;
    $text =~ s/\N{QUESTION EXCLAMATION MARK}/?!/g;
    $text =~ s/\N{EXCLAMATION QUESTION MARK}/!?/g;

    return $text;
}
