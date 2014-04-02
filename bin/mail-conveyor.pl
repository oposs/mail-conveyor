#!/usr/bin/env perl

require 5.014;
use strict;

use FindBin;
use lib "$FindBin::Bin/../thirdparty/lib/perl5";

use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);
use Pod::Usage 1.14;
use Data::Dumper;

use File::Basename;
use File::Temp qw(tempfile);
use Net::LDAP;
use Term::ReadKey;
use YAML::XS;

# parse options
my %opt = ();

# main loop
sub main {
    my @mandatory = (qw(oldserver=s newserver=s popruxidb=s));
    GetOptions(\%opt, qw(help|h man noaction|no-action|n debug ldap|l ldapfilter=s userfile|f cyrusmigration cyrusfiles=s domain=s oldpassword=s newpassword=s olduser=s newuser=s resetmigrated), @mandatory ) or exit(1);

    if ($opt{help})    { pod2usage(1);}
    if ($opt{man})     { pod2usage(-exitstatus => 0, -verbose => 2); }
    if ($opt{noaction}){ die "ERROR: don't know how to \"no-action\".\n";  }

    for my $key (map { s/=s//; $_ } @mandatory) {
        if (not defined $opt{$key}) {
            print STDERR $key.': ';
            ReadMode('noecho') if $key =~ /pass/;
            chomp($opt{$key} = <>);
            if ($key =~ /pass/) {
                ReadMode(0);
                print STDERR "\n";
            }
        }
    }

    my ($users, $filter);

    # fetch config
    my $config = readConfig();

    # fetch users
    if ($opt{ldap} and not defined $opt{userfile}) {
        $filter = $config->{LDAP}->{filter};
        $filter =~ s|_LDAPFILTER_|$opt{ldapfilter}|g;
        $users = fetchUserFromLDAP($config, $filter);
    } else {
        $users = fetchUserFromfile($config);
    }

    # ask proceed with selected users
    proceedWithSelectedUsers($users);

    # special mode for premigration
    if ($opt{resetmigrated}) {
        print STDERR "Reset migrated users now \n";
        adminLDAPWriter($config, $filter, $config->{LDAP}->{premigration});
        exit 0;
    }

    if ($opt{cyrusmigration}) {
        # data from cyrus and provide data to zimbra
        my ($fh, $filename) = tempfile();
        getZimbraProvisioningCommands($users,  $fh, $filename);
        setZimbraProvisioningCommands($config, $fh, $filename);
        File::Temp::cleanup();
    }

    # sync emails
    for my $user (keys $users) {
        print "Syncing Mails for User: $user \n";
        $filter = $config->{LDAP}->{filter};
        $filter =~ s|_LDAPFILTER_|(uid=$user)|g;
        writeLDAPAttribute($config, $filter, $config->{LDAP}->{migration});
        syncEmailsImap($users->{$user});
        matchPopUid($users->{$user});
        writeLDAPAttribute($config, $filter, $config->{LDAP}->{postmigration});
    }
    exit 0;
}


sub readConfig {
	my $config = YAML::XS::LoadFile("$FindBin::Bin/../etc/mail-conveyor.yml");
	if ($opt{debug}) { 
		print "### Config ###\n", Dumper $config;
	}
	return $config;
}

sub proceedWithSelectedUsers {
	my $users = shift;
	print STDERR "## Selected users: ##\n";
	for my $user (sort keys $users) {
		print STDERR " $user \n";
	}
	print STDERR "Do you want proceed? Then type here YES \n";
	chomp(my $proceed = <>);
	unless ($proceed eq 'YES') {
		exit 255;
	}
}

sub fetchUserFromFile {	
	my $config = shift;
	my $users = ();
	for my $uid (sort keys $config->{Users}) {
		for my $key (sort keys $config->{Users}->{$uid}) {
			my $value = $config->{Users}->{$uid}->{$key};
			if ($value =~ m/^_/) {
				$value = $opt{$key};
			}
			$users->{$uid}->{$key} = $value;
		}
	}
	if ($opt{debug}) {
        print "### Users ###\n", Dumper $users;
    }
	return $users;
}

sub __searchInLDAP {	
	my $host = shift;
	my $binduser = shift;
	my $bindpassword = shift;
	my $base = shift;
	my $filter = shift;

	# bind to LDAP server
	my $ldap = Net::LDAP->new($host);
	my $mesg = $ldap->bind(
		$binduser ,
		password => $bindpassword );
	$mesg->code && die $mesg->error;

	# search and filter entries in LDAP
	$mesg = $ldap->search(
		base   => $base,
		filter => $filter,
	);
	$mesg->code && die $mesg->error;

	# check entries in debug mode
	if ($opt{debug}) {
		print "Users selected in LDAP: \n";
		if ($mesg->entries == 0) {
			print "--> no entries found in LDAP <--\n";
		}
		if ($mesg->entries > 1) {
			print "--> " . $mesg->entries." entries found in LDAP <--\n";
		}
	}

	return ($ldap, $mesg);

}

sub fetchUserFromLDAP {
	my $config = shift;
	my $filter = shift;
	my $users = ();

	if ($opt{debug}) {
		print "### FILTER ###\n", Dumper $filter;
	}
	my ($ldap, $mesg) = __searchInLDAP( $config->{LDAP}->{server},
                                        $config->{LDAP}->{binduser},
                                        $config->{LDAP}->{bindpassword},
                                        $config->{LDAP}->{base},
                                        $filter );

	# action loop for all entries
	for my $node (0 .. ($mesg->entries - 1)) {
		my $entry = $mesg->entry($node);
		my $uid = $entry->get_value('uid');
		if ($opt{debug}) {
			print "    $node: $uid\n";
		}
		for my $key (sort keys $config->{LDAP}->{userkeyfields}) {
			my $value = $config->{LDAP}->{userkeyfields}->{$key};
			if ($value =~ m/^_/) {
				$value = $opt{$key};
			} else {
				$value = $entry->get_value($config->{LDAP}->{userkeyfields}->{$key});
			}
			$users->{$uid}->{$key} = $value;
		}
	}
	$ldap->unbind();
	if ($opt{debug}) {
        print "### Users ###\n", Dumper $users;
    }
	return $users;
}

sub writeLDAPAttribute {
	my $config = shift;
	my $filter = shift;
	my $modification = shift;

	my ($ldap, $mesg) = __searchInLDAP( $config->{LDAP}->{server},
                                        $config->{LDAP}->{adminbinduser},
                                        $config->{LDAP}->{adminbindpassword},
                                        $config->{LDAP}->{base},
                                        $filter );

	# action loop for all entries
	for my $node (0 .. ($mesg->entries - 1)) {
		my $entry = $mesg->entry($node);
        my $dn = $entry->dn;
		my $uid = $entry->get_value('uid');
		for my $key (keys $modification) {
			my $ret = $ldap->modify ( $dn, replace => { $key => $modification->{$key} } );
			print STDERR "$uid : " . $ret->error ."\n";
		}
	}
	$ldap->unbind();
}

sub syncEmailsImap {
	my $user = shift;
	my $fh;
	open($fh,
         '-|',
         "$FindBin::Bin/../thirdparty/bin/imapsync",
         '--host1', 	 $user->{oldserver}   ? $user->{oldserver}   : $opt{oldserver},
         '--user1', 	 $user->{username}    ? $user->{username}    : $opt{oldusername},
         '--password1',  $user->{oldpassword} ? $user->{oldpassword} : $opt{oldpassword},
         '--host2', 	 $user->{newserver}   ? $user->{newserver}   : $opt{newserver},
         '--user2', 	 $user->{username}    ? $user->{username}    : $opt{newusername},
         '--password2',  $user->{newpassword} ? $user->{newpassword} : $opt{newpassword},
         '--delete2',
     ) or do { print STDERR "Cannot Sync with imapsync\n"; };

	while (<$fh>) {
		# chomp;
		print $_;
	}
	close($fh);
}

sub matchPopUid {
	my $user = shift;
	my $fh;
	open($fh,
         '-|',
         "$FindBin::Bin/../../popruxi/bin/uidmatcher.pl",
         '--oldserver', $user->{oldserver}   ? $user->{oldserver}   : $opt{oldserver},
         '--olduser', 	$user->{username}    ? $user->{username}    : $opt{oldusername},
         '--oldpass', 	$user->{oldpassword} ? $user->{oldpassword} : $opt{oldpassword},
         '--newserver',	$user->{newserver}   ? $user->{newserver}   : $opt{newserver},
         '--newuser', 	$user->{username}    ? $user->{username}    : $opt{newusername},
         '--newpass', 	$user->{newpassword} ? $user->{newpassword} : $opt{newpassword},
         '--dbfile',    $opt{popruxidb}
     ) or do { print STDERR "Cannot sync UIDLs\n"; };

	while (<$fh>) {
		# chomp;
		print $_;
	}
	close($fh);
}

sub getZimbraProvisioningCommands {
    my $users = shift;
    my $temp_fh = shift;
    my $temp_filename = shift;

    my $cyrus2zmprov;
    my $commands;

    my @args = (
        "$FindBin::Bin/../../popruxi/bin/cyrus2zmprov.pl",
        '--root',      $opt{cyrusfiles},
        '--domain',    $opt{domain}
    );
    for my $user (keys $users) {
        push @args, "$users->{$user}->{username}=$users->{$user}->{alias}";
    }

    open ($temp_fh);
    open ($cyrus2zmprov,
          '-|',
          @args
      ) or do { print STDERR "Cannot run cyrus2zmprov script\n"; };
    while (<$cyrus2zmprov>) {
        print $_;
        print $temp_fh $_;
    }
    close($cyrus2zmprov);
    close($temp_fh);
}

sub activateZimbraProvisioningCommands {
    my $config = shift;
    my $temp_fh = shift;
    my $temp_filename = shift;
    my $fh;

    my $temp_filename_dir  = dirname($temp_filename);
    my $temp_filename_name = basename($temp_filename);
    my @scp_args = (
        '/usr/bin/scp',
        '-i', $config->{ZimbraSSH}->{keyfile},
        "$temp_filename",
        "$config->{ZimbraSSH}->{login}\@$config->{ZimbraSSH}->{host}:$temp_filename_dir/$temp_filename_name",
    );
    open ($fh,
          '-|',
          @scp_args
      ) or do { print STDERR "Cannot run transfer data to Zimbra host\n"; };
    close($fh);

    my @ssh_args = (
        '/usr/bin/ssh',
        '-l', $config->{ZimbraSSH}->{login},
        '-i', $config->{ZimbraSSH}->{keyfile},
        $config->{ZimbraSSH}->{host},
        $config->{ZimbraSSH}->{zmprov},
        '-f', "$temp_filename_dir/$temp_filename_name"
    );
    open($fh,
         '-|',
         @ssh_args
     ) or do { print STDERR "Cannot call remote zmprov\n"; };
    while(<$fh>){
        # chomp;
        print $_;
    }
    close($fh);

    @ssh_args = (
        '/usr/bin/ssh',
        '-l', $config->{ZimbraSSH}->{login},
        '-i', $config->{ZimbraSSH}->{keyfile},
        $config->{ZimbraSSH}->{host},
        '/usr/bin/unlink',
        "$temp_filename_dir/$temp_filename_name"
    );
    open($fh,
         '-|',
         @ssh_args
     ) or do { print STDERR "Cannot unlink file $temp_filename\n"; };
    while(<$fh>){
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

     --man            show man-page and exit
 -h, --help           display this help and exit
     --version        output version information and exit

     --debug          prints debug messages

     -noaction        noaction mode

 -l  --ldap           ldap mode
     --ldapfilter     search filter for and in LDAP
 -f  --userfile       userfile mode

     --oldserver      old server address
     --newserver      new server address

     --propruxidb     path and name to popruxi database
     --cyrusmigration enables cyrus2zmprov / Cyrus -> Zimbra migration
     --cyrusfiles     path to cyrus files for cyrus2zmprov
     --domain         email domain for cyrus2zmprov

=head1 DESCRIPTION

This tool migrate users from one email system to another and integrates
the toolboxes and scripts of imapsync and popruxi.

This script will get an amount of users from LDAP or from a flatfile
and will process the email migration for each user.

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
 2014-03-17 rp added self remigration mode (revert migration LDAP flags)
 2014-04-02 rp added cyrus2zimbra parts from popruxi

=cut

# Emacs Configuration
#
# Local Variables:
# mode: cperl
# eval: (cperl-set-style "PerlStyle")
# mode: flyspell
# mode: flyspell-prog
# End:
#
# vi: sw=4
