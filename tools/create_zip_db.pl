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
#   Download the ZIP1999 data from
#       
#   and put the zipnov99.DBF file in the same directory as this script.
#   Then, run perl create_zip_db.pl. When the script completes, you should
#   have a USzip file to put in your simbot directory.
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
my $sqlite_dbh = DBI->connect('dbi:SQLite:dbname=USzip','','',
    { RaiseError => 1, AutoCommit => 0 })
    or die 'Could not set up SQLite DB!';

$sqlite_dbh->do(<<EOT);
CREATE TABLE uszips (
    zip INTEGER UNIQUE,
    latitude REAL,
    longitude REAL,
    zipclass STRING,
    poname STRING,
    state STRING,
    geocode INTEGER
);
EOT

# we'll create the index when we are done, supposedly it's faster
# that way

my $insert_row_query=$sqlite_dbh->prepare(
    'INSERT INTO uszips'
    . ' (zip, latitude, longitude, zipclass, poname, state, geocode)'
    . ' VALUES (?, ?, ?, ?, ?, ?, ?)'
);

# ok, that's done, now open the dbase III database
my $dbase_dbf = new CAM::DBF('zipnov99.DBF')
    or die 'Could not open zipnov99.DBF';

my $last_row = $dbase_dbf->nrecords() - 1;
print 'Opened the DBF. ' . $dbase_dbf->nrecords() . " rows to read\n";

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
    
    $insert_row_query->execute($cur_row->{'ZIP_CODE'}, $lat,
        $long, $cur_row->{'ZIP_CLASS'},
        $cur_row->{'PONAME'}, $state, $geocode);
}

print "Done!\nCreating indices...";
$sqlite_dbh->do(<<EOT);
CREATE UNIQUE INDEX uszipszip
    ON uszips (zip);

CREATE INDEX uszipsstate
    ON uszips (state);
EOT
print " Done!\nCommitting...";

$sqlite_dbh->commit;
print " Done!\n";