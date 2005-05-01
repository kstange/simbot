###
#  SimBot Aspell Plugin
#
# DESCRIPTION:
#   Provides SimBot the ability to check people's spelling for them. Responds
#   to %spell <word> with a list of suggested spellings.
#
# COPYRIGHT:
#   Copyright (C) 2005, Pete Pearson
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
#   *

package SimBot::plugin::aspell;

use constant DEFAULT_LANGUAGE   => 'en_US';
use constant SUGGESTION_MODE    => 'fast';

use constant CORRECT_SPELLING_BONUS => 50;

use warnings;
use strict;

use Text::Aspell;

use vars qw( $SPELLER );

# MESSUP_ASPELL: Creates the speller. If this fails, we don't load.
sub messup_aspell {
    $SPELLER = Text::Aspell->new or die "Could not create speller";
}

# GET_SPELLING: checks people's spelling
sub get_spelling {
    my ($kernel, $nick, $channel, $self, $word, $lang) = @_;
    if(!$word) {
        &SimBot::send_message($channel, "$nick: I can spell! Sometimes. I think. Try giving me a word to spell, we can find out...");
    } elsif($SPELLER->check($word)) {
        &SimBot::send_message($channel, "$nick: $word is spelled correctly.");
    } else {
        my @suggestions = $SPELLER->suggest($word);
        if($#suggestions > 10) { $#suggestions = 10; }
        &SimBot::send_message($channel, "$nick: Suggestions for '$word': "
            . join(', ', @suggestions));
    }
}

# SCORE_WORD: gives a score modifier to a word
sub score_word {
    my $word = $_[1];
    if($SPELLER->check($word)) {
        &SimBot::debug(4, "$word:+" . CORRECT_SPELLING_BONUS . '(aspell) ');
        return CORRECT_SPELLING_BONUS;
    }
}

&SimBot::plugin_register(plugin_id      => 'spell',
                         plugin_desc    => 'Checks your spelling.',
                         event_plugin_call  => \&get_spelling,
                         event_plugin_load  => \&messup_aspell,
                         query_word_score   => \&score_word,
                         
                         );