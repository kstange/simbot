###
#  SimBot Dice & Coin Plugin
#
# DESCRIPTION:
#   Every IRC needs to be able to roll some dice of arbitrary sides for its
#   regulars, and SimBot is no exception. Responds to '%roll' with a pair of
#   6 sided dice, or to '%roll xdy' with x y-sided dice. It can
#   also flip a coin with '%flip'.
#
# COPYRIGHT:
#   Copyright (C) 2003-04, Pete Pearson
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
#   *
#

package SimBot::plugin::roll;

use strict;
use warnings;

sub roll_dice {
    my $numDice = 2;
    my $numSides = 6;
    my ($kernel, $nick, $channel, undef, $dice) = @_;
    if($dice =~ m/(\d*)[Dd](\d+)/) {
        $numDice = (defined $1 ? $1 : 1);
        $numSides = $2;
    }
    if($numDice == 0) {
        &SimBot::send_message($channel, "$nick: I can't roll zero dice!");
	} elsif($numDice > 100000000000000) {
        &SimBot::send_message($channel, "$nick: I can't even count that high!");
    } elsif($numDice > 100) {
        &SimBot::send_action($channel, "drops $numDice ${numSides}-sided dice on the floor, trying to roll them for ${nick}.");
    } elsif($numSides == 0) {
        &SimBot::send_action($channel, "rolls $numDice zero-sided " . (($numDice==1) ? 'die' : 'dice') . " for ${nick}: " . (($numDice==1) ? "it doesn't" : "they don't") . ' land, having no sides to land on.');
    } elsif($numSides > 1000) {
        &SimBot::send_message($channel, "$nick: The numbers on the dice are so small that I can't read them!");
    } else {
        my @rolls = ();
        for(my $x=0;$x<$numDice;$x++) {
            push(@rolls, int rand($numSides)+1);
        }

        &SimBot::send_action($channel, "rolls $numDice ${numSides}-sided " . (($numDice==1) ? 'die' : 'dice') . " for ${nick}: " . join(' ', @rolls));
    }
}

sub flip_coin {
    my ($kernel, $nick, $channel, undef, $number) = @_;
	my $text;
	$number = 1 if !defined $number;
	if ($number > 20) {
		&SimBot::send_message($channel, "$nick: It's dangerous to throw that many coins in the air at once.");
	} elsif ($number <= 0) {
		&SimBot::send_action($channel, "tries to flip $number coins for $nick, but the universe appears firmly opposed to the idea.");
	} else {
		$text = "";
		for (my $i=1; $i < $number; $i++) {
			$text .= ((int rand(2)==0) ? 'heads, ' : 'tails, ');
		}
		$text .= ((int rand(2)==0) ? 'heads.' : 'tails.');
		&SimBot::send_action($channel, "flips " .
							 ($number > 1 ? "$number coins" : "a coin") .
							 " for $nick: " . $text);
	}
}

sub nlp_match {
    my ($kernel, $nick, $channel, $plugin, @params) = @_;
	my $sides = 6;
	my $dice = 2;
	my $coins = 1;
	my %quantities = (
					  "some", "4",
					  "few", "3",
					  "couple", "2",
					  "couple of", "2",
					  "handful of", "10",
					  "a", "1",
					  "no", "0",
					  "an", "1",
					  "the", "1",
					  "many", "12",
					  "several", "7",
					  "lot of", "30",
					  "lots of", "30",
					  "copious", "42",
					  "plenty of", "72",
					  "excessive", "1000",
					  "every", "100000000000001",
					  "all the", "100000000000001",
					  "all", "100000000000001",
					  "0", "0",
					  );
	my $qmatch = "(" . join("|", keys(%quantities)) . ")";
	$qmatch = qr/$qmatch/i;

	if ($plugin eq "roll") {
		foreach (@params) {
			no warnings;
			if (m/(\d+|$qmatch) (die|dice)/i) {
				$dice = ($1 != 0 ? $1 : $quantities{$1});
			} elsif (m/\bdie\b/i) {
				$dice = 1;
			}

			if (m/(\d+|$qmatch) (\d+|$qmatch)-sided/i) {
				$dice = ($1 != 0 ? $1 : $quantities{$1});
				$sides = ($2 != 0 ? $2 : $quantities{$2});
			} elsif (m/(\d+|$qmatch)-sided/i) {
				$sides = ($1 != 0 ? $1 : $quantities{$1});
			} elsif (m/(\d+|$qmatch) (side|sides|sided)/i) {
				$sides = ($1 != 0 ? $1 : $quantities{$1});
			} elsif (m/\bside\b/i) {
				$sides = 1;
			}
		}

		&roll_dice($kernel, $nick, $channel, undef, $dice . "d" . $sides);
	}

	if ($plugin eq "flip") {
		foreach (@params) {
			no warnings;
			if (m/(\d+|$qmatch) (coin|coins)/i) {
				$coins = ($1 != 0 ? $1 : $quantities{$1});
			} elsif (m/(coins)/i) {
				$coins = 2;
			}
		}

		&flip_coin($kernel, $nick, $channel, undef, $coins);
	}

	return 1;
}

sub SimBot::plugin::flip::nlp_match {
	&SimBot::plugin::roll::nlp_match(@_);
}

# Register Plugins
&SimBot::plugin_register(plugin_id   => "roll",
						 plugin_desc => "Rolls dice. You can specify how many dice, and how many sides, in the format 3D6.",

						 event_plugin_call => \&roll_dice,

						 hash_plugin_nlp_verbs =>
						 ["roll"],
						 hash_plugin_nlp_subjects =>
						 ["dice", "die"],
						 hash_plugin_nlp_formats =>
						 ["{q} die", "{q} dice",
						  "{has} {q} sides", "{has} {q} side",
						  "{q} {q}-sided", "{q}-sided",
						  "{q} {q} sided", "{q} sided", ],
						 hash_plugin_nlp_questions =>
						 ["you-must", "you-should", "you-may",
						  "what-if", "how-about", "i-need",
						  "i-want", "would-you", "command",],
						 );

&SimBot::plugin_register(plugin_id   => "flip",
						 plugin_desc => "Flips a coin.",

						 event_plugin_call => \&flip_coin,

						 hash_plugin_nlp_verbs =>
						 ["flip", "toss"],
						 hash_plugin_nlp_subjects =>
						 ["coin", "coins"],
						 hash_plugin_nlp_formats =>
						 ["{q} coins", "{q} coin", ],
						 hash_plugin_nlp_questions =>
						 ["you-must", "you-should", "you-may",
						  "what-if", "how-about", "i-need",
						  "i-want", "would-you", "command",],
						 );
