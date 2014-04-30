#!/usr/bin/env perl
use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../thirdparty/lib/perl5";

use 5.010;

use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);
use Pod::Usage 1.14;
use Data::Dumper;

use Net::LDAP;
use Term::ReadKey;
use YAML::XS;

# parse options
my %opt = ();

# main loop
sub main {
    my @mandatory = (qw(defaultcosid=s defaultdomain=s));
    GetOptions(\%opt, qw(help|h man noaction|no-action|n debug ldapfilter=s), @mandatory) or exit(1);

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

    if ($opt{help})    { pod2usage(1);}
    if ($opt{man})     { pod2usage(-exitstatus => 0, -verbose => 2); }
    if ($opt{noaction}){ die "ERROR: don't know how to \"no-action\".\n";  }

    # fetch config
    my $config = readConfig();

    # fetch users
    my $filter = $config->{LDAP}->{filter};
       $filter =~ s|_LDAPFILTER_|$opt{ldapfilter}|g;
    my $users  = fetchUserFromLDAP($config, $filter);

    # ask proceed with selected users
    proceedWithSelectedUsers($users);

    # print zmprov commands to STDOUT
    printZmprov($users);
    exit 0;
}


sub readConfig {
	my $config = YAML::XS::LoadFile("$FindBin::Bin/../etc/zimbra-bulk-create.yml");
	if ($opt{debug}) { 
		say "### Config ###", Dumper $config;
	}
	return $config;
}

sub proceedWithSelectedUsers {
	my $users = shift;
	say "## Selected users: ##";
	for my $user (sort keys $users) {
		say " $user ";
	}
	say "Do you want proceed? Then type here YES";
	chomp(my $proceed = <>);
	unless ($proceed eq 'YES') {
		exit 255;
	}
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
		say "Nodes selected in LDAP:";
		if ($mesg->entries == 0) {
			say "--> no entries found in LDAP <--";
		}
		if ($mesg->entries > 1) {
			say "--> " . $mesg->entries." entries found in LDAP <--";
		}
	}

	return ($ldap, $mesg);

}

sub fetchUserFromLDAP {
	my $config = shift;
	my $filter = shift;
	my $users = ();

	if ($opt{debug}) {
		say "### FILTER ###", Dumper $filter;
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
			say "    $node: $uid";
		}
        for my $key (sort keys $config->{LDAP}->{specialfields}) {
            my $value = $entry->get_value($config->{LDAP}->{specialfields}->{$key});
            $users->{$uid}->{specialfields}->{$key} = $value;
        }
        for my $key (sort keys $config->{LDAP}->{fields}) {
            my $value = $entry->get_value($config->{LDAP}->{fields}->{$key});
            $users->{$uid}->{fields}->{$key} = $value;
        }
	}
	$ldap->unbind();
	if ($opt{debug}) {
        	say "### Users ###", Dumper $users;
    	}
	return $users;
}

sub printZmprov {
	my $users = shift;
    for my $user (sort keys $users){
        my $create;
        $create .= 'createAccount'.' ';
        $create .= $user.'@'.$opt{defaultdomain}. ' ';
        $create .= $users->{$user}->{specialfields}->{password} . ' \\' . "\n";
        $create .= "\t" . 'displayname ' . "\"$users->{$user}->{fields}->{gn} $users->{$user}->{fields}->{sn}\"" . ' \\' . "\n";
        $create .= "\t" . 'zimbraPasswordMustChange FALSE' . ' \\' . "\n";
        for my $k (keys $users->{$user}->{fields}) {
            $create .= "\t" . $k . ' ' . $users->{$user}->{fields}->{$k} . ' \\' ."\n";
        }
        $create .= "\t" . 'zimbraCOSid ' . $opt{defaultcosid} . "\n";
        print $create;
    }
}

main;

__END__

=head1 NAME

zimbra-build-create.pl - creates a Zimbra bulk creation zmprov file for importing users

=head1 SYNOPSIS

B<zimbra-build-create.pl> [I<options>...]

     --man            show man-page and exit
 -h, --help           display this help and exit
     --version        output version information and exit

     --debug          prints debug messages

     --ldapfilter     filter extension for the LDAP search

     --defaultdomain  Default Domain for each created user

     --defaultcosid   COS ID of the default COS


=head1 DESCRIPTION

This script will query an LDAP for user attributes. The LDAP search
amount can be filtered by the filter argument in the config file and
also with the ldapfilter argument on the command line.

zimbra-build-create will print an zmprov output which can be inserted
to the Zimbra system with

    zmprov -f zimbra-bulk-create.txt

=head2 Example

Example configuration file:

Content of ./etc/zimbra-bulk-create.yml

   LDAP:
    server:       ldap://ldap.example.com
    binduser:     cn=ldapsearchuser,dc=example,dc=com
    bindpassword: secret
    base:         dc=example,dc=com
    filter:       (&(objectClass=Users)_LDAPFILTER_)

    specialfields:
        username:   uid
        alias:      mail
        password:   plainpassword

    fields:
        gn:               givenname
        sn:               sn
        c:                c
        zimbraPrefLocale: lang

Run bulk creation script:

  ./bin/zimbra-bulk-create.pl \
       --defaultdomain=example.com \
       --defaultcosid=ABCD-EFG-1234 \
       --ldapfilter '(uid=rplessl)'

   ## Selected users: ##
      rplessl
   Do you want proceed? Then type here YES

    createAccount rplessl@example.com PASSWORD \
	   displayname "Roman Plessl" \
       zimbraPasswordMustChange FALSE \
	   zimbraPrefLocale de \
	   gn Roman \
	   sn Plessl \
	   c CH \
	   zimbraCOSid ABCD-EFG-1234


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

 2014-04-04 rp Initial Version

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