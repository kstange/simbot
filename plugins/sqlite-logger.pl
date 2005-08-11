###
#  SimBot sqlite Logger Plugin
#
# DESCRIPTION:
#   Logs chat SimBot sees to a SQLite log. This could be used to 
#   generate channel statistics, a more intelligent seen plugin, and
#   more.
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
#   * see comment at about line 600
#


package SimBot::plugin::sqlite::logger;

use warnings;
use strict;
use Data::Dumper;

use Time::Local;
use HTML::Entities;

use vars qw( $dbh $insert_query $get_nickchan_id_query $get_nickchan_name_query $add_nickchan_id_query );

use DBI;

use constant MONTHS => ('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug',
    'Sep','Oct','Nov','Dec');
    
use constant MAX_RESULTS => 20;

use constant REQUESTED_TOO_MANY => 'Sorry, but I cannot send you more than '
    . MAX_RESULTS . ' results.';
    
use constant REQUESTED_NONE => "No, I don't think I'll be doing that.";

use constant SEEN_HELP => <<EOT;
  %bold%<nick>%bold% is the nickname of the person you are looking for, or '*' to match
    anybody.
  %bold%<events>%bold% can be one or more of join, part, quit, kick, say, action, topic
  %bold%count <number>%bold% will return as many results as exist, up to <number>
    You'll get one result if you don't specify a count
  %bold%content <phrase>%bold% will match results that contain the phrase
%seen before that
    will repeat your last search, looking for an older match
EOT

sub messup_sqlite_logger {
    $dbh = DBI->connect(
        'dbi:SQLite:dbname=data/irclog',
        '','', # user, pass aren't useful to SQLite
        { RaiseError => 1, AutoCommit => 0 }
    ) or die;
    &SimBot::debug(3, 'sqlite: Using SQLite version '
        . $dbh->{'sqlite_version'} . "\n");
        
    # let's create our table. If this fails, we don't care.
    {
        local $dbh->{RaiseError}; # let's not die in this block
        local $dbh->{PrintError}; # and let's be quiet
        $dbh->do(<<EOT);
CREATE TABLE chatlog (
    id INTEGER PRIMARY KEY,
    time INTEGER,
    channel_id INTEGER,
    source_nick_id INTEGER,
    event STRING,
    target_nick_id INTEGER,
    content STRING);
EOT

        $dbh->do(<<EOT);
CREATE TABLE names (
    id INTEGER PRIMARY KEY,
    name STRING,
    context STRING);
EOT
        $dbh->commit;
    }
    
    # let's prepare the insert query now, it'll be used a lot so
    # keeping it ready is a good idea
    $insert_query = $dbh->prepare(
        'INSERT INTO chatlog '
        . ' (time, channel_id, source_nick_id, target_nick_id, event, content) '
        . ' VALUES (?, ?, ?, ?, ?, ?)'
    );
    
    # and the query to fetch a nick ID
    $get_nickchan_id_query = $dbh->prepare(
        'SELECT id FROM names'
        . ' WHERE lower(name) = lower(?)'
        . ' LIMIT 1'
    );
    
    # and the query to fetch a nick name from ID
    $get_nickchan_name_query = $dbh->prepare(
        'SELECT name FROM names WHERE id = ? LIMIT 1' );
    
    # and the query to add one
    $add_nickchan_id_query = $dbh->prepare(
        'INSERT INTO names (name) VALUES (?)'
    );
}

sub cleanup_sqlite_logger {
    $dbh->disconnect;
}

# get_nickchan_id is called whenever a nickname ID or channel ID is
# needed.
# name will be the name of the chnanel or nickname
sub get_nickchan_id {
    my ($name, $add_unknown) = @_;
    my $id;
    
    $get_nickchan_id_query->execute($name) or die;
    if(($id) = $get_nickchan_id_query->fetchrow_array()) {
    	# The nickname is known.
        $get_nickchan_id_query->finish;
    } else {
    	# The nickname isn't known. We might need to add it.
        $get_nickchan_id_query->finish;
        if($add_unknown) {
            $add_nickchan_id_query->execute($name);
            $id = $dbh->last_insert_id(undef,undef,'names',undef);

            $add_nickchan_id_query->finish;
        } else {
            return undef;
        }
    }
    return $id;
}

# get_nickchan_name reverses get_nickchan_id
sub get_nickchan_name {
    my ($id) = @_;
    my $name;
    
    $get_nickchan_name_query->execute($id) or die;
    ($name) = $get_nickchan_name_query->fetchrow_array();
    $get_nickchan_name_query->finish;
    return $name;
}

sub log_nick_change {
    my (undef, undef, $nick, $newnick) = @_;
    my $channel_id = &get_nickchan_id(
        &SimBot::option('network', 'channel'), 0
    );
    
    my $source_nick_id = &get_nickchan_id($nick, 1);
    my $target_nick_id = &get_nickchan_id($newnick, 1);
    
    # FIXME: This causes two "uninitialized value" warnings.
    # I don't know why. They appear to be harmless, though, so
    # I give up. I'm surpressing the warnings, someone else can
    # fix 'em.
    {
        no warnings qw( uninitialized );
        $insert_query->execute(time, $channel_id, $source_nick_id,
            $target_nick_id, 'NICK', undef);
    }
    $insert_query->finish;
    $dbh->commit;
}

sub set_seen {
    # lots of undefs here, and we mean 'em all. Shut up about it.
    no warnings qw( uninitialized );
    
    my($kernel, $nick, $channel, $doing, $content, $target) = @_;
    my $time = time;

    # First, we need to identify things
    my $channel_id = &get_nickchan_id(
        &SimBot::option('network', 'channel'),
        1
    );
    my $source_nick_id = &get_nickchan_id($nick, 1);
    my $target_nick_id;
    
    if($doing eq 'KICKED') {
        # IRC kicks are foo got kicked by bar
        # let's store it so that foo is the target.
        $target_nick_id = $source_nick_id;
        $source_nick_id = &get_nickchan_id($target, 1);
    } elsif($doing eq 'MODE') {
        # $target will be the arguments for the mode change options
        # let's add them to the content
        $content .= " $target";
    } elsif($doing eq 'ACTION') {
        (undef, $content) = split(/ /, $content, 2);
    }
    
    $insert_query->execute(time, $channel_id, $source_nick_id, $target_nick_id, $doing, $content);
    $insert_query->finish;
    $dbh->commit;
}

sub do_seen {
    my ($kernel, $nick, $channel, undef, @args) = @_;
    
    my $nick_id = &get_nickchan_id($nick);
    
    my ($seen_nick, $seen_row);
    my @events;
    my $count=1;
    my $content;
    
    my $nick_list;
    
    if(!defined $args[0]) {
        # the user did a %seen without any arguments
        &SimBot::send_message($channel,
            "$nick: Who are you looking for? ('%seen --help' for more options)");
        return;
    } elsif($args[0] =~ m/--help/i) {
        &SimBot::send_message($channel, "$nick: OK, messaging you help.");
        &SimBot::send_pieces_with_notice($nick, undef, SEEN_HELP);
        return;
    } elsif($args[0] eq 'before' && $args[1] eq 'that') {
        my $context = &get_nick_context($nick_id);
        
        if($context =~ m/seen=(\d+)/) {
            $nick_list = $1;
        } else {
            &SimBot::send_message($channel,
                "$nick: I don't seem to remember what 'that' is.");
            return;
        }
        if($context =~ m/seen-row=(\d+)/) {
            $seen_row = $1;
        } else {
            die 'This shouldn\'t happen!';
        }
        if($context =~ m/seen-event=(\S+)/) {
            @events = split(/,/, $1);
        }
        if($context =~ m/seen-content="(.*?)"/) {
            $content = $1;
        }
        
    } else {
        $seen_nick = shift(@args);
        &SimBot::debug(3, "sqlite-logger: Seen request by $nick for $seen_nick\n");

        if($seen_nick =~ m/^\*$/) {
            # user is looking for anybody
            # we'll do nothing
        } elsif($seen_nick =~ m/\*/) {
            # user is using wildcards
            # FIXME: Later.
            &SimBot::send_message($channel,
                "$nick: Sorry, wildcard matching is not implemented yet.");
            return;
        } elsif(!($nick_list = &get_nickchan_id($seen_nick))) {
            # The requested nick does not exist.
            &SimBot::send_message($channel,
                "$nick: I do not know of a $seen_nick");
            return;
        }
    
        while(my $cur_arg = shift(@args)) {
            if($cur_arg =~ /(say|join|part|quit|nick|kick|notice|action|topic)/i) {
                my $cur_event = $1;
                if($cur_event =~ /^(join|part|kick)$/i) 
                    { $cur_event .= 'ed'; }
                    
                push(@events, uc($cur_event));
            } elsif($cur_arg =~ m/before/) {
                my $time = shift(@args);
                
            } elsif($cur_arg =~ m/count/) {
                $count = shift(@args);
            } elsif($cur_arg =~ m/^content$/) {
                $content = join(' ', @args);
                last;
            }
        }
    }
    
    if(!defined $count) {
        &SimBot::send_message($channel, "$nick: 'count' must be followed by the number of results you want.");
        return;
    } elsif($count <= 0) {
        &SimBot::send_message($channel, "$nick: " . REQUESTED_NONE);
        return;
    } elsif($count > MAX_RESULTS) {
        &SimBot::send_message($channel, "$nick: " . REQUESTED_TOO_MANY);
        return;
    }


    # Build the query string
    my $seen_query;
    my $query_str = 
        'SELECT id, time, source_nick_id, event,'
        . ' target_nick_id, content'
        . ' FROM chatlog WHERE channel_id = ?';
    if(defined $nick_list) {
        $query_str .= ' AND (source_nick_id IN (' . $nick_list . ')'
        . ' OR target_nick_id IN (' . $nick_list . '))';
    }
    if(defined $seen_row) {
        $query_str .= " AND id < $seen_row"; 
    }
    if(@events) {
        $query_str .= 
            " AND event IN ('" . join("','", @events) . "')";
    }
    if(defined $content) {
        $query_str .= ' AND content LIKE '
            . $dbh->quote('%' . $content . '%');
    }
    $query_str .= ' ORDER BY time DESC'
        . ' LIMIT ' . $count;
    
    unless($seen_query = $dbh->prepare($query_str)) {
        &SimBot::send_message($channel,
            "$nick: Sorry, but something went wrong accessing the log.");
        return;
    }
    $seen_query->execute(&get_nickchan_id(&SimBot::option('network', 'channel')));
    my $row;
    my $last_id;
    my @responses;
    while($row = $seen_query->fetchrow_hashref) {
        unshift(@responses, &row_hashref_to_text($row));
        $last_id = $row->{'id'};
    }
    $seen_query->finish;
    
    if(!@responses) {
        # no responses
        &SimBot::send_message($channel,
            "$nick: Nothing matched your query.");
    } elsif($#responses == 0) {
        # only one response, give it in the channel.
        &SimBot::send_message($channel, "$nick: $responses[0]");
    } else {
        # many responses
        &SimBot::send_message($channel, "$nick: OK, messaging you " . ($#responses + 1) . ' results.');
        &SimBot::send_pieces_with_notice($nick, undef, join("\n", @responses));
    }
    
    # update context so 'before that' works
    {
        no warnings qw( uninitialized );
        &update_nick_context($nick_id, 'seen-row', $last_id);
        &update_nick_context($nick_id, 'seen', $nick_list);
        &update_nick_context($nick_id, 'seen-event',
            join(',', @events));
        &update_nick_context($nick_id, 'seen-content', qq("${content}"));
    }
}

sub do_recap {
    my ($kernel, $nick, $channel, undef, @args) = @_;
    # let's autorecap!
    # first, we need to find when the person asking for the recap
    # left.
    
    my $nick_id = &get_nickchan_id($nick);
    
    my $start_query = $dbh->prepare_cached(
        'SELECT id FROM chatlog'
        . ' WHERE channel_id = ?'
        . ' AND source_nick_id = ?'
        . ' AND (event = \'PARTED\''
        . ' OR event = \'QUIT\''
        . ' OR event = \'KICKED\')'
        . ' ORDER BY time DESC'
        . ' LIMIT 1'
    );
    
    my $end_query = $dbh->prepare_cached(
        'SELECT id FROM chatlog'
        . ' WHERE channel_id = ?'
        . ' AND source_nick_id = ?'
        . ' AND event = \'JOINED\''
        . ' ORDER BY time DESC'
        . ' LIMIT 1'
    );
    
    my $log_query = $dbh->prepare_cached(
        'SELECT time, source_nick_id, event,'
        . ' target_nick_id, content'
        . ' FROM chatlog'
        . ' WHERE channel_id = ?'
        . ' AND id >= ?'
        . ' AND id <= ?'
    );
    
    my $channel_id = &get_nickchan_id(
        &SimBot::option('network', 'channel')
    );
    $start_query->execute(
        $channel_id,
        $nick_id
    );
    
    my $start_row;
    unless(($start_row) = $start_query->fetchrow_array) {
        $start_query->finish;
        &SimBot::send_message($channel,
            "$nick: Sorry, I didn't see you leave!"
        );
        return;
    }
    $start_query->finish;
    
    $end_query->execute(
        $channel_id,
        $nick_id
    );
    my $end_row;
    unless(($end_row) = $end_query->fetchrow_array) {
        $end_query->finish;
        &SimBot::send_message($channel,
            "$nick: Sorry, I didn't see you come back!"
        );
        return;
    }
    $end_query->finish;
    
    # ok, so now we have the range to fetch...
    # let's get it!
    $log_query->execute($channel_id, $start_row, $end_row);
    if($log_query->rows == 2) {
        $log_query->finish;
        # the log only shows the person leaving and joining
        &SimBot::send_message($channel,
            "$nick: Nothing happened while you were gone."
        );
        return;
    }
    
    my @msg;
    my $row;
    while($row = $log_query->fetchrow_hashref) {
        push(@msg, &row_hashref_to_text($row));
    }
    $log_query->finish;
    if($#msg > MAX_RESULTS) {
        $msg[-(MAX_RESULTS)] = "[ Recap too long, giving you the last 20 lines ]";
        @msg = @msg[-(MAX_RESULTS)..-1];
    }
    &SimBot::send_pieces_with_notice($nick, undef,
        join("\n", @msg));
}

sub access_log {
    my ($kernel, $nick, $channel, $self, $query, @args) = @_;
    my $nick_id;
    
    if($query =~ m/^recap$/) {
        &do_recap($kernel, $nick, $channel, undef, @args);
    } elsif($query =~ m/^seen/) {
        &do_seen($kernel, $nick, $channel, undef, @args);
    } elsif($query =~ m/^last/) {
        #FIXME: remove this. Eventually.
        my $count;
        if($args[0] =~ /^\d+$/) {
            $count = shift(@args);
        }
        my $seen_query = '%seen * ' . $args[0];
        if(defined $count) { $seen_query .= " count $count"; }
        &SimBot::send_message($channel, "$nick: %log last has been replaced by %seen. Try: $seen_query");
    } elsif($query =~ m/^stats/) {
        my $statnick = $args[0];
        my $chan_id = &get_nickchan_id(&SimBot::option('network','channel'));
        
        $nick_id = &get_nickchan_id($nick);
        
        if(!defined $statnick) {
            # no nick specified, so how 'bout some generic stats?
            my $tmp_query;
            
            $tmp_query = $dbh->prepare_cached(
                'SELECT time FROM chatlog'
                . ' WHERE channel_id = ?'
                . ' ORDER BY time'
                . ' LIMIT 1');
            $tmp_query->execute($chan_id);
            my $start_date = localtime(($tmp_query->fetchrow_array())[0]);
            $tmp_query->finish;
            
            $tmp_query = $dbh->prepare_cached(
                'SELECT count() FROM chatlog'
                . ' WHERE channel_id = ?'
            );
            $tmp_query->execute($chan_id);
            my $log_size = ($tmp_query->fetchrow_array())[0];
            $tmp_query->finish;
            
            my $response =
                "$nick: I have been logging since $start_date."
                . " I have seen $log_size lines.";
                
                # I have seen $log_size lines and $nick_count nicks.";
            
            # add today's lines and today's nicks.
            
            &SimBot::send_message($channel, $response);
        } else {
            my $statnick_id;
            unless($statnick_id = &get_nickchan_id($statnick)) {
                &SimBot::send_message($channel,
                    "$nick: I do not know of a $statnick");
                return;
            }
            
            my $response = "$nick:";
            my @reply_has;
            
            my $tmp_query = $dbh->prepare_cached(
                'SELECT time FROM chatlog'
                . ' WHERE channel_id = ?'
                . ' AND (source_nick_id = ?'
                . ' OR target_nick_id = ?)'
                . ' ORDER BY time'
                . ' LIMIT 1');
            $tmp_query->execute($chan_id, $statnick_id, $statnick_id);
            my $first_date = localtime(($tmp_query->fetchrow_array())[0]);
            $tmp_query->finish;
            
            $tmp_query = $dbh->prepare_cached(
                'SELECT time FROM chatlog'
                . ' WHERE channel_id = ?'
                . ' AND (source_nick_id = ?'
                . ' OR target_nick_id = ?)'
                . ' ORDER BY time DESC'
                . ' LIMIT 1');
            $tmp_query->execute($chan_id, $statnick_id, $statnick_id);
            my $last_date = localtime(($tmp_query->fetchrow_array())[0]);
            $tmp_query->finish;
            
            $response .= " I first saw $statnick on $first_date,"
                . " and most recently on $last_date.";
            
            my $target_query = $dbh->prepare_cached(
                'SELECT count() FROM chatlog'
                . ' WHERE channel_id = ?'
                . ' AND target_nick_id = ?'
                . ' AND event = ?'
            );
            my $source_query = $dbh->prepare_cached(
                'SELECT count() FROM chatlog'
                . ' WHERE channel_id = ?'
                . ' AND source_nick_id = ?'
                . ' AND event = ?'
            );
            
            my $value;
            $source_query->execute($chan_id, $statnick_id, 'SAY');
            $value = ($source_query->fetchrow_array())[0];
            push(@reply_has, "spoken $value line"
                . ($value > 1 ? 's' : ''))
                if $value > 0;
            
            $source_query->execute($chan_id, $statnick_id, 'ACTION');
            $value = ($source_query->fetchrow_array())[0];
            push(@reply_has, "emoted $value time"
                . ($value > 1 ? 's' : ''))
                if $value > 0;
            
            $source_query->execute($chan_id, $statnick_id, 'TOPIC');
            $value = ($source_query->fetchrow_array())[0];
            push(@reply_has, "set the topic $value time"
                . ($value > 1 ? 's' : ''))
                if $value > 0;
            
            $source_query->execute($chan_id, $statnick_id, 'KICKED');
            $value = ($source_query->fetchrow_array())[0];
            push(@reply_has, "kicked others $value time"
                . ($value > 1 ? 's' : ''))
                if $value > 0;
            
            $target_query->execute($chan_id, $statnick_id, 'KICKED');
            $value = ($target_query->fetchrow_array())[0];
            push(@reply_has, "been kicked $value time"
                . ($value > 1 ? 's' : ''))
                if $value > 0;
            
            
            # join count ("I have seen JohnDoe 52 times, first on 
            #   Jan 42, 87:43 AM, and most recently on...")
            # kicked count, kicking count
            # "is a nightowl" if some percent of logged days
            #   contains at least one line between midnight and 5?
            # "graveyard shift", "morning crew" similar?
            # "is a yeller" if some percentage of lines are all caps?
            # "is verbose" if most lines are long?
            # "1z l4m3" if uses l4m3r sp33k? (probably too hard to
            #    look up.

	    # most of those seem to be hard to look up... the counts are easy
	    # nightowl etc might not be too hard, it's just comparing counts

            if(@reply_has) {
                $response .= " $statnick has "
                    . join(', ', @reply_has) . '.';
            }
            &SimBot::send_message($channel, $response);
        }
    } else {
        &SimBot::send_message($channel, "$nick: Sorry, I do not understand that. Try 'recap', 'seen <nick>', 'stats' for channel stats, or 'stats <nick>' for someone's stats.");
    }
}

sub row_hashref_to_text {
    my ($row) = @_;
    
    my (undef, undef, undef, $cur_day, $cur_month, $cur_yr) = localtime; 
    $cur_month += 1; # localtime gives us 0..11, we want 1..12
    $cur_yr += 1900; # localtime gives us number of years since 1900
    
    my (undef, $min, $hr, $day, $month, $yr) = localtime($row->{'time'});
    $month += 1;
    $yr += 1900;
    
    my $msg = '[';
    
    if($cur_day != $day || $cur_month != $month || $cur_yr != $yr) {
        $msg .= (MONTHS)[$month-1] . " $day ";
    }
    
    if($cur_yr != $yr) { $msg .= "$yr "; }
    
    $msg .= $hr . ':' . sprintf('%02d',$min) . '] ';
    
    if($row->{'event'} eq 'SAY') {
        $msg .= '<' . &get_nickchan_name($row->{'source_nick_id'})
        . '> ' . $row->{'content'};
    } elsif($row->{'event'} eq 'NOTICE') {
        $msg .= '-' . &get_nickchan_name($row->{'source_nick_id'})
        . '- ' . $row->{'content'};
    } elsif($row->{'event'} eq 'ACTION') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
		. ' ' . $row->{'content'};
    } elsif($row->{'event'} eq 'JOINED') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'}) 
            . ' joined.';
    } elsif($row->{'event'} eq 'PARTED') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' left (' . $row->{'content'} . ')';
    } elsif($row->{'event'} eq 'QUIT') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' quit (' . $row->{'content'} . ')';
    } elsif($row->{'event'} eq 'TOPIC') {
        if($row->{'content'}) {
            $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
                . ' changed the topic to: ' . $row->{'content'};
        } else {
            $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
                . ' cleared the topic.';
        }
    } elsif($row->{'event'} eq 'MODE') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' set ' . $row->{'content'};
    } elsif($row->{'event'} eq 'KICKED') {
        $msg .= '* ' . &get_nickchan_name($row->{'target_nick_id'})
            . ' was kicked by '
            . &get_nickchan_name($row->{'source_nick_id'})
            . ' (' . $row->{'content'} . ')';
    } elsif($row->{'event'} eq 'NICK') {
        $msg .= '* ' . &get_nickchan_name($row->{'source_nick_id'})
            . ' is now known as '
            . &get_nickchan_name($row->{'target_nick_id'});
            
    } else {    # Oh, great, we forgot one.
        $msg .= 'UNKNOWN EVENT ' . $row->{'event'} . ':';
        if(defined $row->{'source_nick_id'})
            { $msg .= ' source:' . &get_nickchan_name($row->{'source_nick_id'}); }
        if(defined $row->{'target_nick_id'})
            { $msg .= ' target:' . &get_nickchan_name($row->{'target_nick_id'}); }
        if(defined $row->{'content'})
            { $msg .= ' content:' . $row->{'content'}; }
    }
    return $msg;
}

# This turns the row hashref into a hashref with a human readable timestamp
# and user nicks instead of IDs.
sub row_hashref_to_template_hashref {
    my ($row) = @_;
    
    # TIMESTAMP
    my (undef, undef, undef, $cur_day, $cur_month, $cur_yr) = localtime; 
    $cur_month += 1; # localtime gives us 0..11, we want 1..12
    $cur_yr += 1900; # localtime gives us number of years since 1900
    
    my (undef, $min, $hr, $day, $month, $yr) = localtime($row->{'time'});
    $month += 1;
    $yr += 1900;
    
    $row->{'timestamp'} = '';
    if($cur_day != $day || $cur_month != $month || $cur_yr != $yr) {
        $row->{'timestamp'} .= (MONTHS)[$month-1] . " $day ";
    }
    
    if($cur_yr != $yr) { $row->{'timestamp'} .= "$yr "; }
    
    $row->{'timestamp'} .= $hr . ':' . sprintf('%02d',$min);
    
    
    # NICKS
    if(defined $row->{'source_nick_id'}) {
        $row->{'source_nick'} =
            &get_nickchan_name($row->{'source_nick_id'});
    }
    if(defined $row->{'target_nick_id'}) {
        $row->{'target_nick'} =
            &get_nickchan_name($row->{'target_nick_id'});
    }
    
    # CONTENT
    if(defined $row->{'content'}) {
        $row->{'content'} = &f_content($row->{'content'});
    }
    
    return $row;
}


### FORMATTING FUNCTIONS ###

# f_content is used to format the content part of chat.
# this does things like linkify URLs, escape characters that
# need escaping, munge email addresses, and things like that.
sub f_content {
    my $content = $_[0];
    $content = encode_entities($content);
    
    # linkify
    $content = &linkify($content);
    
    return $content;
}


sub get_nick_context {
    my ($nick_id) = @_;
    
    my $query = $dbh->prepare_cached(
        'SELECT context FROM names WHERE id = ?'
    );
    $query->execute($nick_id);
    my ($context) = $query->fetchrow_array;
    $query->finish;
    return $context;
}

sub update_nick_context {
    my ($nick_id, $key, $value) = @_;
    
    my $context = &get_nick_context($nick_id);
    
    if(!defined $value || $value eq  '') {
        unless($context =~ s/${key}=\S+//) {
            # we're trying to unset the value, but it wasn't set
            # no need to commit to the database
            return;
        }
    } elsif($context !~ s/${key}=\S+/${key}=${value}/) {
        $context .= " ${key}=${value}";
    }
    
    my $query = $dbh->prepare_cached(
        'UPDATE names SET context = ? WHERE id = ?'
    );
    $query->execute($context, $nick_id);
}

# SCORE_WORD: Gives a score modifier to a word
# for seen, we give bonus to words that are the
# nicknames of people we have seen.
sub score_word {
    my $word = $_[1];
    if (get_nickchan_id($word)) {
	   &SimBot::debug(4, "${word}:+1000(sqlite-logger) ", SimBot::DEBUG_NO_PREFIX);
	   return 1000;
    }
    &SimBot::debug(5, "${word}:+0(sqlite-logger) ", SimBot::DEBUG_NO_PREFIX);
    return 0;
}

sub seen_nlp_match {
    my ($kernel, $nick, $channel, $plugin, @params) = @_;

	my $person;

	foreach (@params) {
		if (m/(\w+) (seen|here)/i) {
			$person = $1;
		} elsif (m/(see|seen) (\w+)/i) {
			$person = $2;
		}
	}

	if (defined $person) {
		$person = $SimBot::chosen_nick if ($person eq "you"
										   || $person eq "yourself");
		$person = $nick if ($person eq "me");
		&do_seen($kernel, $nick, $channel, undef, $person);
		return 1;
	} else {
		return 0;
	}
}

sub web_request {
    my ($request, $response, $get_template) = @_;
    
    my $query = &create_query_hash($request->uri);
    
    if(defined $query->{'recap'}) {
        return &web_recap($query, $response, $get_template);
    } else {
        return &web_log($query, $response, $get_template);
    }
}

sub web_recap {
    my ($query, $response) = @_;
    
    return 501; # not implemented
}

sub web_log {
    my ($query, $response, $get_template) = @_;
    my (undef, undef, undef, $start_day, $start_month, $start_year)
        = localtime;
    
    $start_month += 1;
    $start_year += 1900;
    
    my ($start_hour, $start_min, $end_hour, $end_min);
    $start_hour = $start_min = 0;
    $end_hour = 23;
    $end_min = 59;
    
    my $channel_id = (defined $query->{'channel_id'}
                      ? $query->{'channel_id'}
                      : &get_nickchan_id(&SimBot::option('network', 'channel')));
    
    if(defined $query->{'smo'})
        { $start_month = $query->{'smo'}; }
    if(defined $query->{'sdy'})
        { $start_day = $query->{'sdy'}; }
    if(defined $query->{'syr'})
        { $start_year = $query->{'syr'}; }
    if(defined $query->{'shr'})
        { $start_hour = $query->{'shr'}; }
    if(defined $query->{'smn'})
        { $start_min = $query->{'smn'}; }
    
    # If the end day, month, year aren't set, assume the same as the
    # start
    my ($end_day, $end_month, $end_year)
        = ($start_day, $start_month, $start_year);
        
    if(defined $query->{'emo'})
        { $end_month = $query->{'emo'}; }
    if(defined $query->{'edy'})
        { $end_day = $query->{'edy'}; }
    if(defined $query->{'eyr'})
        { $end_year = $query->{'eyr'}; }
    if(defined $query->{'ehr'})
        { $end_hour = $query->{'ehr'}; }
    if(defined $query->{'emn'})
        { $end_min = $query->{'emn'}; }
        
    my $start_time = timelocal(0,$start_min,$start_hour,$start_day, $start_month-1, $start_year);
    my $end_time = timelocal(59,$end_min,$end_hour,$end_day, $end_month-1, $end_year);
        
    my $log_query = $dbh->prepare_cached(
        'SELECT time, source_nick_id, event, target_nick_id, content'
        . ' FROM chatlog'
        . ' WHERE channel_id = ?'
        . ' AND time >= ?'
        . ' AND time <= ?'
    );
    
    $log_query->execute($channel_id, $start_time, $end_time);
    
    my $row;
    my @loop_data;
    while($row = $log_query->fetchrow_hashref) {
        push(@loop_data, &row_hashref_to_template_hashref($row));
    }
    
    my $irclog_template = &$get_template('irclog');
    $irclog_template->param(
        ircloop => \@loop_data,
        channel => &get_nickchan_name($channel_id),
        start_time => scalar localtime($start_time),
        end_time => scalar localtime($end_time),
    );
    
    my $base_template = &$get_template('base');
    $base_template->param(
        content => $irclog_template->output(),
        title => 'IRC Log',
    );
    
    $response->content($base_template->output());
    $response->push_header("Content-Type", "text/html");
    return 200; # OK
}

sub create_query_hash {
    my ($query) = $_[0] =~ m/\?(\S+)$/;
    my %hash;
    if(!defined $query) { return \%hash; }
    
    foreach my $cur_query (split(/&/, $query)) {
        my ($key, $value) = $cur_query =~ m/^(\S+)(?:=(\S+))$/;
        
        if(!defined $value) { $value = 1; }
        
        $hash{$key} = $value;
    }
    
    return \%hash;
}

sub linkify {
    my $line = $_[0];
    
    my $bold = 0;
    my $reverse = 0;
    my $underline = 0;
    my $color = -1;
    my $bgcolor = -1;
    my $tag = '';
    
    while(my @codes = $line =~ m/(?:&#(2|3|15|22|31);)+/) {
        my $block = $&;
        foreach my $code (@codes) {
            if ($code == 2) {
                $bold = 1 - $bold;
            } elsif ($code == 31) {
                $underline = 1 - $underline;
            } elsif ($code == 22) {
                $reverse = 1 - $reverse;
            } elsif ($code == 3) {
                $line =~ m/&#3;(\d{1,2})?(,(\d{1,2}))?/;
                if ($2) {
                    $color = $1 if $1;
                    $bgcolor = $3;
                    $line =~ s/&#3;$1$2/&#3;/;
                } elsif ($1) {
                    $color = $1;
                    $line =~ s/&#3;$1/&#3;/;
                } else {
                    $color = -1;
                    $bgcolor = -1;
                }
            } else {
                $bold = 0;
                $underline = 0;
                $reverse = 0;
                $color = -1;
                $bgcolor = -1;
            }
        } #end foreach code
        
        if ($tag =~ /<span/) {
            $tag = "</span>";
        } else {
            $tag = '';
        }
        
        my $class =
            ($bold          ? 'bold '   : '')
            . ($underline   ? 'uline '  : '')
            . ($reverse     ? 'reverse '
                : ($color != -1     ? "color$color " : '')
                . ($bgcolor != -1   ? "bgcolor$color "  : '')
            );
        
        $tag .= "<span class=\"$class\">" if ($class ne "");
        $line =~ s/$block/$tag/;
    } # end while blocks
    $line .= "</span>" if ($tag =~ /<span/);
    
    my @words = split(/\s+/, $line);
    my $curWord;

    foreach $curWord (@words) {        
        # remove things that commonly surround URLs
        my ($word_prefix, $word, $word_suffix) = $curWord
            =~ m@^(["'\(<\[]?)(\S*?)(["'\)>\]]?)$@; #'
        my $url = $word;

        # map some common host names to protocols
        $url =~ s{^(www|web)\.} {http://$1\.};
        $url =~ s{^ftp\.}       {ftp://ftp\.};
        
        if($url =~ m{^(\S+)@(\S+)\.(\S+)$}) {
            # probably an email address
            $curWord = &SimBot::html_mask_email($url);
            next;
        }
        
        if($url =~ m{^((http|ftp|news|nntp|irc|aim)s?:[\w.?/=\-\&\;]+)}) {
            $curWord = qq($word_prefix<a href="$1">$word</a>$word_suffix);
            next;
        }
        
        if(my ($host, $path) = $url =~ m{(.+?)/(.*)}) {
            # does the first segment have a TLD?
            if($host =~ m{\.(com|org|net|edu|gov|mil|int
                            |biz|pro|info|aero|coop|name
                            |museum|\w\w)$}ix) {
                # Yup. Let's assume it's a web site...
                $host = 'http://' . $host;
                
                $curWord = qq($word_prefix<a href="${host}/${path}">$word</a>$word_suffix);
            }
        }
    }
    return join(' ', @words);
}

&SimBot::plugin_register(
    plugin_id               => 'log',
    event_plugin_call       => \&access_log,
    event_plugin_load       => \&messup_sqlite_logger,
    event_plugin_unload     => \&cleanup_sqlite_logger,
    event_channel_kick      => \&set_seen,
    event_channel_message       => \&set_seen,
    event_channel_message_out   => \&set_seen,
    event_channel_action        => \&set_seen,
    event_channel_action_out    => \&set_seen,
    event_channel_notice        => \&set_seen,
    event_channel_notice_out    => \&set_seen,
    event_channel_topic     => \&set_seen,
    event_channel_join      => \&set_seen,
    event_channel_part      => \&set_seen,
    event_channel_mejoin    => \&set_seen,
    event_channel_quit      => \&set_seen,
    event_channel_mode      => \&set_seen,
    event_server_nick       => \&log_nick_change,
    query_word_score        => \&score_word,

);

&SimBot::plugin_register(
    plugin_id               => 'seen',
	plugin_params           => "<nick> [<events>] [count <number>] [content <phrase>]",
    plugin_help             => SEEN_HELP,
    event_plugin_call       => \&do_seen,
    event_plugin_nlp_call   => \&seen_nlp_match,
    hash_plugin_nlp_verbs   => ['seen', 'see'],
    hash_plugin_nlp_formats => ['{w} here', 'see {w}', '{w} seen', 'seen {w}'],
    hash_plugin_nlp_questions => ['have-you', 'did-you', 'when-is', ],
);
    
$SimBot::hash_plugin_httpd_pages{'log'} = {
    'title' => 'Log Viewer',
    'handler' => \&web_request,
}
