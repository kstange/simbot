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
#   * Set a default language, and allow the user to query other dictionaries
#     instead of the default.

package SimBot::plugin::aspell;

# What suggestion mode to use? May be one of:
#   ultra, fast, normal, slow, bad-spellers
# fast is recommended. See http://aspell.sourceforge.net/man-html/Notes-on-the-Different-Suggestion-Modes.html
# for more information on the different modes.
use constant SUGGESTION_MODE    => 'fast';

use constant CORRECT_SPELLING_BONUS => 50;

use warnings;
use strict;

use Text::Aspell;

use vars qw( $SPELLER %DICTS );

# MESSUP_ASPELL: Creates the speller. If this fails, we don't load.
sub messup_aspell {
    $SPELLER = Text::Aspell->new or die "Could not create speller";
    $SPELLER->set_option('sug-mode', SUGGESTION_MODE);
    $SPELLER->set_option('lang', (&SimBot::option('plugin.aspell', 'lang')
                                    ? &SimBot::option('plugin.aspell', 'lang')
                                    : 'en'));
    
    my $cur;
    
    foreach $cur ($SPELLER->list_dictionaries) {
        my ($cur_dict) = split(/:/, $cur, 2);
        $DICTS{$cur_dict} = 1;
    }
    1;
}

# GET_SPELLING: checks people's spelling
sub get_spelling {
    my ($kernel, $nick, $channel, $self, $word, $lang) = @_;
    my $cur_speller;
    if($lang) {
        if(defined $DICTS{$lang}) {
            # Let's create a speller for the user's langauge...
            $cur_speller = Text::Aspell->new;
            $cur_speller->set_option('lang', $lang);
            $cur_speller->set_option('sug-mode', SUGGESTION_MODE);
        } else {
            &SimBot::send_message($channel, "$nick: I don't have a dictionary ${lang}, try one of: " . join(' ', keys %DICTS));
            return;
        }
    } else {
        # use the global speller
        $cur_speller = $SPELLER;
    }
    
    if(!$word) {
        &SimBot::send_message($channel, "$nick: I can spell! Sometimes. I think. Try giving me a word to spell, we can find out...");
    } elsif($cur_speller->check($word)) {
        &SimBot::send_message($channel, "$nick: $word is spelled correctly.");
    } else {
        my @suggestions = $cur_speller->suggest($word);
        if(@suggestions) {
            if($#suggestions > 10) { $#suggestions = 10; }
            &SimBot::send_message($channel, "$nick: Suggestions for '$word': "
                . join(', ', @suggestions));
        } else {
            &SimBot::send_message($channel, "$nick: No suggestions for '$word'.");
        }
    }
}

# SCORE_WORD: gives a score modifier to a word
sub score_word {
    if(CORRECT_SPELLING_BONUS) {
        my $word = $_[1];
        if($SPELLER->check($word)) {
            &SimBot::debug(4, "$word:+" . CORRECT_SPELLING_BONUS . '(aspell) ');
            return CORRECT_SPELLING_BONUS;
        }
    }
    return 0;
}

&SimBot::plugin_register(plugin_id      => 'spell',
						 plugin_params  => "<word> [<language>]",
                         plugin_help    => "Checks your spelling.\n%bold%<language>%bold% specifies the language code to use, such as 'en' or 'en_US' The default is 'en'",
                         event_plugin_call  => \&get_spelling,
                         event_plugin_load  => \&messup_aspell,
                         query_word_score   => \&score_word,
                         
                         );
