# SimBot Dice & Coin Plugin
#
# Copyright (C) 2003, Pete Pearson
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

package SimBot::plugin::roll;

sub roll_dice {
    my $numDice = 2;
    my $numSides = 6;
    my ($kernel, $nick, $channel, undef, $dice) = @_;
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
    } elsif($numSides > 1000) {
        $kernel->post(bot => privmsg => $channel, "$nick: The numbers on the dice are so small that I can't read them!");
    } else {
        my @rolls = ();
        for(my $x=0;$x<$numDice;$x++) {
            push(@rolls, int rand($numSides)+1);
        }

        $kernel->post(bot => ctcp => $channel, 'ACTION', "rolls $numDice ${numSides}-sided " . (($numDice==1) ? 'die' : 'dice') . " for ${nick}: " . join(' ', @rolls));
    }
}

package SimBot::plugin::flip;

sub flip_coin {
    my ($kernel, $nick, $channel) = @_;
    $kernel->post(bot => ctcp => $channel, 'ACTION', "flips a coin for $nick: "
        . ((int rand(2)==0) ? 'heads' : 'tails'));
}

# Register Plugins
SimBot::plugin_register(plugin_id   => "roll",
			plugin_desc => "Rolls dice. You can specify how many dice, and how many sides, in the format 3D6.",
			modules     => "",

			event_plugin_call => "roll_dice",
			);

SimBot::plugin_register(plugin_id   => "flip",
			plugin_desc => "Flips a coin.",
			modules     => "",

			event_plugin_call => "flip_coin",
			);