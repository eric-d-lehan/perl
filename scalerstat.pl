#!/usr/bin/perl -w
#####################
###elehan
###Script to easily find and stat objects on the netscalers
#####################
use strict;
use warnings;
use Getopt::Long;
use DBI;
use Scalar::Util;



my $help;
my $filter;
my $version;
my $versionname="0.1.6";
my $createdb;
my $type;
my $server;
my $list;
my $grep;
my $batch;
my $dump;
my $watch;
my $surgecheck;
my $quiet;

my $datafileloc = "/path/to/nfs/share/scaler-data.dbl";
my @scalerlist = ('scaler1', 'scaler2', 'scaler3', 'scaler4', 'scaler5', 'scaler6');

my $state = GetOptions('help' => \$help,
						"filter=s" => \$filter,
						"version" => \$version,
						"createdb" => \$createdb,
						"type=s" => \$type,
						"batch" => \$batch,
						"server=s" => \$server,
						"list" => \$list,
						'grep' => \$grep,
						'dbdump' => \$dump,
						'watch' => \$watch,
						'surgecheck|sc' => \$surgecheck,
						'quiet' => \$quiet,
						);

if ($state == 0 && $ARGV[0] eq "") { &printUsage(); exit 0;}
if (!defined $ARGV[0]) { $ARGV[0] = ""; } 
if (!($ARGV[0] eq "") && (!defined $filter) ) {$filter = $ARGV[0];} #if there is anything left after getops is done, consider it a filter


OPTIONSWITCH: {
	if (defined $version) { &printVersion(); exit 0;}
        if (defined $help) { &printUsage(); exit 0;}
        if (defined $createdb) { &createdb(); exit 0;}
        if (defined $list) { &netscalerlist(); exit 0;}
        if (defined $dump) { &dumpTable(); exit 0;}
}

&main();


##########################
###Run the main logic
###Determin which logic path we will be following 
#########################

sub main() {

	OPTIONSWITCH: {
		if (defined $filter && defined $surgecheck) { &getSurgesFromClusterStatables(); last; exit 0;}
		if (defined $filter && !defined $grep) { &selectKeyList(); last; exit 0;}
		if (defined $filter && defined $grep) { &scalersearch(); last; exit 0;}
		else {print "No valid commandline option combination chosen, please see help\n\n"; &printUsage(); last; exit 0};
	}
 
}

##############################
###create and populate the database
##############################
sub createdb() {
	if ( -e $datafileloc ) { `rm $datafileloc` ; `touch $datafileloc` } else { `touch $datafileloc`} #if the file exists, remove it. create an empty file to use

	my $dbh = DBI->connect( "dbi:SQLite:$datafileloc" ) || die "Cannot connect: $DBI::errstr"; #use dbi to connected to sqlite database
	$dbh->do( "CREATE TABLE statables ( identity, caller, scalername )" );
	my $ps = $dbh->prepare( "INSERT INTO statables VALUES ( ?, ?, ? ) ");

	foreach (@scalerlist) { #for every netscaler run through the state looking only for lines that begin with add, then tear apart those looking for info needed to stat them and add them to database
		my $servername = $_;

		my @scalarinput = `ssh nsroot\@$servername sh ru | egrep "^add"`;

		foreach my $line (@scalarinput) {
			chomp($line);
			my ($first,$second,$third,$fourth,$fifth) = split(' ', $line);

			VALSWITCH: { #actual inserts into the database and printing * every time one is found to show progress
				if (defined $second && $second eq "lb" && $third ne "monitor") { $ps->execute( $fourth, "$second $third", $servername ); print '*'}
				if (defined $second && $second eq "cs" && $third ne "policy") { $ps->execute( $fourth, "$second $third", $servername ); print '*'}
				if (defined $second && $second eq "serviceGroup") { $ps->execute( $third, $second, $servername ); print '*'}
				if (defined $second && $second eq "service") { $ps->execute( $third, $second, $servername ); print '*'}
			}
		}
		print "\n";
	}
	$dbh->disconnect;
}

############################################################
###show a list of statable items based on a database search.
###present them in a numbered list and prompt for a number.
###Then stat the statable associated with that number.
############################################################
sub selectKeyList() {
	print "filter is: $filter\n";
	my $dbh = DBI->connect( "dbi:SQLite:$datafileloc" ) || die "Cannot connect: $DBI::errstr";
	my $ps1 = $dbh->prepare("SELECT identity, caller, scalername FROM statables WHERE identity like ?");
	my $ps2 = $dbh->prepare("SELECT identity, caller, scalername FROM statables WHERE identity like ? AND caller=?");
	my $ps3 = $dbh->prepare("SELECT identity, caller, scalername FROM statables WHERE identity like ? AND scalername=?");
	my $ps4 = $dbh->prepare("SELECT identity, caller, scalername FROM statables WHERE identity like ? AND scalername=? AND caller=?");
	
	my $res;
	SELECTSWITCH: {
		if ( (defined $filter) && !(defined $type) && !(defined $server) ) {$ps1->execute('%'.$filter.'%'); $res = $ps1->fetchall_arrayref; last;}
		if ( (defined $filter) && (defined $type) && !(defined $server) ) {print "$filter $type\n"; $ps2->execute('%'.$filter.'%', $type); $res = $ps2->fetchall_arrayref; last;} 
		if ( (defined $filter) && !(defined $type) && (defined $server) ) {$ps3->execute('%'.$filter.'%', $server); $res = $ps3->fetchall_arrayref; last;}
		if ( (defined $filter) && (defined $type) && (defined $server) ) {$ps4->execute('%'.$filter.'%', $server, $type); $res = $ps4->fetchall_arrayref; last;}
		else {print "No valid commandline option combination chosen, please see help\n"; last; exit 0};
		if ($res < 0) { print $DBI::errstr;exit 0;}

	}

	my @listings;
	my $listingloc = 1;
	if (!defined $batch) { ### if this is not a batch run, print out the selection list
		foreach( @$res ) { #print out the stat ssh commandline for each statable
			print "$listingloc) ssh nsroot\@$_->[2] stat $_->[1] $_->[0]\n";
			push(@listings, "ssh nsroot\@$_->[2] stat $_->[1] $_->[0]");
			$listingloc++;
		}
	} else {###in batch mode don't present a list, just output all of the statables
		foreach( @$res ) {
			print "ssh nsroot\@$_->[2] stat $_->[1] $_->[0]\n";
			print `ssh nsroot\@$_->[2] stat $_->[1] $_->[0]`;
		}
		exit 0;
	}
	
	my $listingslen = @listings;
	if ($listingslen == 0) {print "Sorry, no statable matched your string.\n"; exit 0;} #if there are no listings. exit the program
	my $line;
	if ($listingslen == 1) { $line = 1;} # if there is only one possible statable, skip question and answer phase and just print statable
	else { #question and answer phase
		print "[STAT Number or (q)uit] ";
		$line = readline(*STDIN); #collect the number from user
		chomp($line);
		if ($line eq "q" || $line eq "quit") {exit 0;} #if they choose q or quit, leave the program
		my $tracker = getValidNumber($line, $listingslen);
		until($tracker) {
			print "Invalid option please choose between 1-$listingslen or (q)uit\n";
			print "[STAT Number or (q)uit] ";
			$line = readline(*STDIN); #collect the number from user
			chomp($line);
			if ($line eq "q" || $line eq "quit") {exit 0;} #if they choose q or quit, leave the program
			$tracker = getValidNumber($line, $listingslen);
		}
		print "statting $line\n";
	}
	$line = $line-1;
	print "$listings[$line]\n";
	if ($watch) { ### output a repeating display of surge on the statable
		for (my $i=0; $i <= 300; $i++) {
			system("clear");
			print "$listings[$line]\n";
   			print `$listings[$line] | sed -n '/SurgeQ/,/^\$/p'` . "\n"; #perform the actual stat
   			sleep 5;
		}
	} else {
		print `$listings[$line]` . "\n"; #perform the actual stat
	}

	$dbh->disconnect;
}

################################################
###This will find all of the statables in a cluster
###and then stat them one after another looking for surge
################################################
sub getSurgesFromClusterStatables() {
	my $res;
	print "filter is: $filter\n";
	my $dbh = DBI->connect( "dbi:SQLite:$datafileloc" ) || die "Cannot connect: $DBI::errstr";
	my $ps1 = $dbh->prepare("SELECT identity, caller, scalername FROM statables WHERE identity like ? AND caller like ?");
	$ps1->execute('%'.$filter.'%', 'serviceGroup'); $res = $ps1->fetchall_arrayref;

	if ($res < 0) { print $DBI::errstr;exit 0;}

	foreach( @$res ) { #print out the stat ssh commandline for each statable
   		my $results = `ssh nsroot\@$_->[2] stat $_->[1] $_->[0] | sed -n '/SurgeQ/,/^\$/p'`; #perform the actual stat

   		if (!$quiet) {
   			print "ssh nsroot\@$_->[2] stat $_->[1] $_->[0]\n";
   			print "$results" . "\n";
   		} else {
   			my @splitresults = split /\n/, $results;
   			my $surge = 0;
   			my $firstline = 1;
 

   			foreach my $line (@splitresults) {
   				if ($firstline) {$firstline=0; next;}
   				my @columns = split /\s+/, $line;
   				my $numcolumns = @columns;
   				my $SurgeQ = $columns[$numcolumns -2];

   				if ($SurgeQ > 0) {
   					$surge = 1; #if any of line of this shows a surge, then print this group;
   				}
   			}
   			if ($surge) {
   				print "ssh nsroot\@$_->[2] stat $_->[1] $_->[0]\n";
   				print "$results" . "\n";
   			}
   		}
	}

	$dbh->disconnect();
}



################################################
###verify number is valid, if not prompt
###user repeatedly until a valid number is given
################################################
sub getValidNumber($$) {
	my ($number, $listingslen) = @_;
	if (!defined $number || $number eq "") {return 0;} #if no valid option chosen, prevents math errors below from ever being reached if $line = ""
	if ( !(Scalar::Util::looks_like_number($number) )) {return 0;} #if not a number
	if ($number <= -1 || $number >= $listingslen +1) {return 0;} #error checking
	return 1;
}

#############################################
###a replacement for the scaler search script
#############################################
sub scalersearch() {
	foreach(@scalerlist) { #list of scalers defined at top of program
		my $servername = $_;
		my $serverstate = `ssh nsroot\@$servername sh ru | egrep $filter`; #ssh
		if ($serverstate ne "") {
			print "############### $servername ################\n";
			print "$serverstate\n";
		}
	}
}

#######################################################
###just output the list of netscalers suitable for scripts
#######################################################
sub netscalerlist() {
	foreach(@scalerlist) {
		print "$_\n"
	}
}


######################################
###dump out all data from the database
######################################
sub dumpTable() {
	my $dbh = DBI->connect( "dbi:SQLite:$datafileloc" ) || die "Cannot connect: $DBI::errstr"; #use dbi to connected to sqlite database

	my $res = $dbh->selectall_arrayref( "SELECT * FROM statables" );

	foreach my $row (@$res) {
		print "$row->[0]\t\t$row->[1]\t\t$row->[2]\n";
	}

	$dbh->disconnect;
}

##############################
###This is the version message
##############################
sub printVersion() {
        print("$versionname\n");
exit;
}

###########################
###This is the help message
###########################
sub printUsage() {
        print <<END;
Script to easily find and stat objects on the netscalers
Can also be used as a replacement for the scalersearch.sh scripts
Line syntax is

--createdb, -c = If this option is chosen the database will be updated with the current data
--filter, -f = the filter to be checked, this can be the full name or a substring, if a substring it will catch everything like it
if -f or --filter is not defined, the first string which is not an option will be used as the filter
--type, -t = if this is used, only server objects of the appropriate type will be found, eg. serviceGroup, however if you are trying to get a lb vserver you will need to call it like '--type "lb vserver"' 
--server, -s = only list objects belonging to the selected vserver, must be an exact match of the netscaler server name -change to server_id
--grep, -g = instead of searching for statables, it searches each of the netscalers looking for lines that match the grep option and outputs them broken down by the scaler they were found on. When used in the way the grep option can also be an egrep argument
--list, -l = will list the netscalers.
--batch, -b = batch mode. instead of presenting a list of matches, it will instead just run against all matches.
--watch. -w = watch mode. this will only run in single rather then batch mode. will watch the surge of the statable
--dbdump = show all of the contents of the database.
--surgecheck, -sc = check for all surges related to the filter
--quiet, -q = when using surgecheck only show groups that actually have surge.
--help, -h = display this information.
--version, -v = version number

example: $0 searchterm
example: $0 -f searchterm
example: $0 searchterm -f
example: $0 --createdb
example: $0 -f searchterm -t "lb vserver"
example: $0 searchterm -type serviceGroup
example: $0 --filter searchterm --server scaler1 --type="lb vserver"
example: $0 searchterm -g
example: $0 -f '^bind\ lb' -g
This will only work if you are set up to to have passwordless login on the netscaler on the box you run this from and that have DBI and SQLite have been
END
exit;
}
