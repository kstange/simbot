#!/usr/bin/perl

# SimBot ZIP1999 Data Importer
#
# DESCRIPTION:
#   Imports the US Census ZIP code data from 1999 into a sqlite database
#   for use by the weather plugin, and anything else that wants it.
#   You should not need to run this, you should have received a USzip file
#   with simbot.
#
# USAGE:
#   This script needs the following databases to run:
#       COUNTRY         FILENAME
#           URL
#       United States   zipnov99.DBF
#           http://www.census.gov/geo/www/tiger/zip1999.html
#       United Kingdom  jibble-postcodes.csv
#           http://www.jibble.org/ukpostcodes/
#
#   Download these files into the simbot/tools directory.
#   Then, run perl create_postalcode_db.pl. When the script completes, you 
#   should have a postalcodes file in your data directory.
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

use warnings;
use strict;

use CAM::DBF;
use DBI;

$| = 1;

my %states = qw(
    01 AL   02 AK   04 AZ   05 AR   06 CA   08 CO   09 CT   10 DE   11 DC
    12 FL   13 GA   15 HI   16 ID   17 IL   18 IN   19 IA   20 KS   21 KY
    22 LA   23 ME   24 MD   25 MA   26 MI   27 MN   28 MS   29 MO   30 MT
    31 NE   32 NV   33 NH   34 NJ   35 NM   36 NY   37 NC   38 ND   39 OH
    40 OK   41 OR   42 PA   44 RI   45 SC   46 SC   47 TN   48 TX   49 UT
    50 VT   51 VA   53 WA   54 WV   55 WI   56 WY
    
    60 AS   64 FM   66 GU   68 MH   69 MP   70 PW   72 PR   74 UM   78 VI
);


# set up the sqlite database
our $sqlite_dbh = DBI->connect('dbi:SQLite:dbname=../data/postalcodes','','',
    { RaiseError => 1, AutoCommit => 0 })
    or die 'Could not set up SQLite DB!';

$sqlite_dbh->do(<<EOT);
CREATE TABLE postalcodes (
    code STRING UNIQUE,
    latitude REAL,
    longitude REAL,
    poname STRING,
    state STRING,
    country INTEGER,
    geocode INTEGER
);
EOT

$sqlite_dbh->do(<<EOT);
CREATE TABLE countries (
    id INTEGER PRIMARY KEY,
    name STRING UNIQUE,
    code STRING UNIQUE
);
EOT

# we'll create the index when we are done, supposedly it's faster
# that way

my $insert_row_query=$sqlite_dbh->prepare(
    'INSERT OR REPLACE INTO postalcodes'
    . ' (code, latitude, longitude, poname, state, country, geocode)'
    . ' VALUES (?, ?, ?, ?, ?, ?, ?)'
);

# ok, that's done, now open the dbase III database
if( my $dbase_dbf = new CAM::DBF('zipnov99.DBF')) {
    my $country_id = &get_country_id('United States', 'us');
    my $last_row = $dbase_dbf->nrecords() - 1;
    print 'Reading US db. ' . $dbase_dbf->nrecords() . " rows to read\n";
    
    for my $row (0 .. $last_row) {
        if($row % 2500 == 0) {
            print " row $row, " . int (($row/$last_row)*100) . "%\n";
        }
        my $cur_row = $dbase_dbf->fetchrow_hashref($row);
        
        my $lat = $cur_row->{'LATITUDE'};
        my $long = $cur_row->{'LONGITUDE'};
        my $state = $cur_row->{'STATE'};
        my $geocode = $state . sprintf('%03d', $cur_row->{'COUNTY'});
        
        if($states{$state})
            { $state = $states{$state}; }
        
        $lat =~ s/^\s*//;
        $long =~ s/^\s*//;
        
        if($lat == 24.859832 && $long == -168.021815) {
            # Bogus lat/long for many zips in Hawai'i
            # unless there's a post office on the ocean floor.
    
            if($cur_row->{'PONAME'} eq 'HONOLULU') {
                $lat = 21.307039;
                $long = -157.858343;
            } else {
                undef $lat;
                undef $long;
            }
        }
        
        {
            no warnings qw( uninitialized );
            $insert_row_query->execute($cur_row->{'ZIP_CODE'}, $lat,
                $long, $cur_row->{'PONAME'}, $state, $country_id, $geocode);
        }
    }
    print "Done!\n";
}

if(open(IN, 'jibble-postcodes.csv')) {
    my $country_id = &get_country_id('United Kingdom', 'uk');
    <IN>;
    my $line_count = 0;
    print "Reading UK db";
    while(<IN>) {
        
        my($postcode, undef, undef, $latitude, $longitude)
            = split(/,/);
        
        ($longitude) = $longitude =~ m/(-?[\d.]+)/;
        if(++$line_count % 300 == 0) { print '.'; }
        
        no warnings qw( uninitialized );
        $insert_row_query->execute($postcode, $latitude, $longitude, undef, undef, $country_id, undef);
    }
    print " Done! Read $line_count lines\n";
}

print "Creating indices...";
$sqlite_dbh->do(<<EOT);
CREATE UNIQUE INDEX postalcodescode
    ON postalcodes (code);

CREATE INDEX postalcodesstate
    ON postalcodes (state, country);
EOT
print " Done!\nCommitting...";

$sqlite_dbh->commit;
print " Done!\n";

sub get_country_id {
    my ($name, $code) = @_;
    my $id;
    
    my $query = $sqlite_dbh->prepare_cached(
        'SELECT id FROM countries'
        . ' WHERE lower(name) = lower(?)'
        . ' LIMIT 1'
    );
    
    $query->execute($name) or die;
    if(($id) = $query->fetchrow_array()) {
    	# The nickname is known.
        $query->finish;
    } else {
    	# The nickname isn't known. We might need to add it.
        $query->finish;
        $query = $sqlite_dbh->prepare_cached('INSERT INTO countries (name, code) VALUES (?, ?)');
        $query->execute($name, $code);
        $id = $sqlite_dbh->last_insert_id(undef,undef,'names',undef);

        $query->finish;
    }
    return $id;
}