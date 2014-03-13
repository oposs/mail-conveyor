#!/usr/bin/env perl

require 5.014;
use strict;

use FindBin;
use lib "$FindBin::Bin/../thirdparty/lib/perl5";

use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);
use Pod::Usage 1.14;
use Term::ReadKey;
use Data::Dumper;

use Net::LDAP;
use YAML::XS;

# parse options
my %opt = ();

# main loop
sub main()
{
	my @mandatory = (qw(oldserver=s newserver=s popruxidb=s));

	GetOptions(\%opt, qw(help|h man noaction|no-action|n debug ldap|l userfile|f newpassword=s olduser=s newuser=s), @mandatory ) or exit(1);
	if($opt{help})     { pod2usage(1) }
	if($opt{man})      { pod2usage(-exitstatus => 0, -verbose => 2) }
	if($opt{noaction}) { die "ERROR: don't know how to \"no-action\".\n" }
	for my $key (map { s/=s//; $_ } @mandatory){
		if (not defined $opt{$key}){
			print STDERR $key.': ';
			ReadMode('noecho') if $key =~ /pass/;
			chomp($opt{$key} = <>);
			if ($key =~ /pass/){
				ReadMode(0);
				print STDERR "\n";
			}
		}
	}

	# fetch config
	my $config = readConfig(\%opt);
	if($opt{debug}) { print "### Config ###\n", Dumper $config }

	# fetch users
	my $users;
	print Dumper $opt{ldap};

	if ($opt{ldap} and not defined $opt{userfile}) {
		$users = fetchUserFromLDAP(\%opt, $config);
	}
	else {
		$users = fetchUserFromfile(\%opt, $config);
	}
	if($opt{debug}) { print "### Users ###\n", Dumper $users }

	# sync emails
	for my $user (keys $users) {
		print "Syncing Mails for User: $user \n";

		# for testing
		$users->{$user}->{oldpassword} = $opt{oldpassword};

		syncEmailsImap(\%opt, $users->{$user});
		matchPopUid(\%opt, $users->{$user});
	}
}

sub readConfig {
	my $opt = shift;
	my $config = YAML::XS::LoadFile("$FindBin::Bin/../etc/mail-conveyor.yml");
	return $config;
}

sub fetchUserFromFile {
	my $opt = shift;
	my $config = shift;
	my $users = ();
	for my $uid (sort keys $config->{Users}) {
		for my $key (sort keys $config->{Users}->{$uid}){
			my $value = $config->{Users}->{$uid}->{$key};
			if ($value =~ m/^_/) {
				$value = $opt{$key};
			}
			$users->{$uid}->{$key} = $value;
		}
	}
	return $users;
}

sub fetchUserFromLDAP {
	my $opt = shift;
	my $config = shift;
	my $users = ();

	my $LDAP_HOST         = $config->{LDAP}->{server};
	my $LDAP_BINDUSER     = $config->{LDAP}->{binduser};
	my $LDAP_BINDPASSWORD = $config->{LDAP}->{bindpassword};

	# bind to LDAP server
	my $ldap = Net::LDAP->new($LDAP_HOST);
	my $mesg = $ldap->bind(
		$LDAP_BINDUSER ,
		password => $LDAP_BINDPASSWORD );
	$mesg->code && die $mesg->error;

	# search and filter entries in LDAP
	$mesg = $ldap->search(
		base   => $config->{LDAP}->{base},
		filter => $config->{LDAP}->{filter}
	);
	$mesg->code && die $mesg->error;

	# check entries
	if ($mesg->entries == 0) {
		print "no entries found in LDAP\n";
	}
	if ($mesg->entries > 1) {
		print $mesg->entries." entires found in LDAP\n";
	}

	# action loop for all entries
	for my $node (0 .. ($mesg->entries - 1)) {
		# print "ID: $node";
		my $entry = $mesg->entry($node);
		my $uid = $entry->get_value('uid');
		for my $key (sort keys $config->{LDAP}->{userkeyfields}){
			my $value = $config->{LDAP}->{userkeyfields}->{$key};
			if ($value =~ m/^_/) {
				$value = $opt{$key};
			}
			else {
				$value = $entry->get_value($config->{LDAP}->{userkeyfields}->{$key});
			}
			$users->{$uid}->{$key} = $value;
		}
	}
	return $users;
}

sub syncEmailsImap {
	my $opt  = shift;
	my $user = shift;

	my $fh;
	open($fh,
		'-|',
		"$FindBin::Bin/../thirdparty/bin/imapsync",
		'--host1', 		$opt{oldserver},
		'--user1', 		$user->{username},
		'--password1', 	$user->{oldpassword},
		'--host2', 		$opt{newserver},
		'--user2', 		$user->{username},
		'--password2', 	$user->{newpassword},
		'--folder',     'INBOX',
		'--delete2') or do { print STDERR "Cannot Sync with imapsync\n"; };

	while(<$fh>){
		# chomp;
		print $_;
	}
	close($fh);
}

sub matchPopUid {
	my $opt  = shift;
	my $user = shift;

	my $fh;
	open($fh,
         '-|',
         "$FindBin::Bin/../../popruxi/bin/uidmatcher.pl",
         '--oldserver', $opt{oldserver},
         '--olduser', 	$user->{username},
         '--oldpass', 	$user->{oldpassword},
         '--newserver',	$opt{newserver},
         '--newuser', 	$user->{username},
         '--newpass', 	$user->{newpassword},
         '--dbfile',    $opt{popruxidb}) or do { print STDERR "Cannot sync UIDLs\n"; };

	while (<$fh>) {
		# chomp;
		print $_;
	}
	close($fh);
}

main;

__END__

=head1 NAME

mail-conveyor.pl - migrates emails from one to another email system

=head1 SYNOPSIS

B<mail-conveyor.pl> [I<options>...]

	 --man           show man-page and exit
 -h, --help          display this help and exit
	 --version       output version information and exit
	 
	 --debug         prints debug messages

	 --noaction 	 noaction mode

 -l  --ldap 		 ldap mode
 -f  --userfile 	 userfile mode

	 --oldserver     old server address
	 --newserver 	 new server address

	 --propruxidb    path and name to popruxi database

=head1 DESCRIPTION

This tool migrate users from one email system to another and integrates 
the toolboxes and scripts of imapsync and popruxi.

This script will get an amount of users from LDAP or from a flatfile and will
process the email migration for each user.


=head1 LICENSE

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
more details.

You should have received a copy of the GNU General Public License along with
this program.  If not, see L<http://www.gnu.org/licenses/>.

=head1 AUTHOR

S<Roman Plessl E<lt>roman.plessl@oetiker.chE<gt>>

=head1 HISTORY

 2014-03-10 rp Initial Version

=cut
