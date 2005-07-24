# SimBot Magic Eight Ball
#
# Copyright (C) 2005 Pete Pearson
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

package SimBot::plugin::8ball;

use warnings;
use strict;

# http://en.wikipedia.org/wiki/Magic_8-ball
use constant SAYINGS => (
    'Signs point to yes.',
    'Yes.',
    'Reply hazy, try again.',
    'Without a doubt.',
    'My sources say no.',
    'As I see it, yes.',
    'You may rely on it.',
    'Concentrate and ask again.',
    'Outlook not so good.',
    'It is decidedly so.',
    'Better not tell you now.',
    'Very doubtful.',
    'Yes - definitely.',
    'It is certain.',
    'Cannot predict now.',
    'Most likely.',
    'Ask again later.',
    'My reply is no.',
    'Outlook good.',
    "Don't count on it.",
);

use constant BLANK_SAYINGS => (
    'Concentrate and ask again.',
    'Ask again later.',
    'Reply hazy, try again.',
);

# $nick will be replaced by the supplicant's nick
use constant INTROS => (
    q(pulls out a Magic 8 Ball and concentrates deeply on $nick's question:),
    q(drops the magic 8 ball on the floor, catches it as it rolls away, and shows the answer to $nick's question:),
    q(vigorously shakes the 8-ball to find the answer to $nick's question:),
); #'

use constant BLANK_INTROS => (
    q(pulls out a Magic 8 Ball and concentrates deeply on nothingness:),
);


sub consult_the_8ball {
    my ($kernel, $nick, $channel, undef, $question) = @_;
    &SimBot::debug(3, "8ball: Consulting the Magic Eight Ball for $nick\n");
    
    my $message;
    
    if(defined $question) {
        $message = &SimBot::pick((INTROS)) . ' ' . &SimBot::pick((SAYINGS));
    } else {
        $message = &SimBot::pick((BLANK_INTROS)) . ' ' . &SimBot::pick((BLANK_SAYINGS));
    }
    $message =~ s/\$nick/$nick/g;
    
    &SimBot::send_action($channel, $message);
}

# Register plugin
&SimBot::plugin_register(plugin_id => '8ball',
                        plugin_help => 'Consults the Magic 8 Ball. Be sure to ask a question!',
                        plugin_params => '<question>',
                        event_plugin_call => \&consult_the_8ball,
                        );
                        