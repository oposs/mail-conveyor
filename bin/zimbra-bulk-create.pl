#!/usr/bin/env perl
use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../thirdparty/lib/perl5";

use 5.010;

use Getopt::Long qw(:config posix_default no_ignore_case auto_version);
use Pod::Usage;
use Data::Dumper;

use Net::LDAP;
use Term::ReadKey;
use YAML::XS;

our $VERSION = '1.1';

# parse options
my %opt = ();

# main loop
sub main {
    my @mandatory = (qw(defaultcosid=s defaultdomain=s));
    GetOptions(\%opt, qw(help|h man noaction|no-action|n debug ldapuserfilter=s ldapgroupfilter=s), @mandatory) or exit(1);

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

    # fetch config
    my $config = readConfig();

    # apply filter mechanism
    $opt{ldapgroupfilter} = $opt{ldapgroupfilter} // '';
    $opt{ldapuserfilter}  = $opt{ldapuserfilter}  // '';

    my $users  = fetchUserFromLDAP($config);

    # ask proceed with selected users
    proceedWithSelectedUsers($users);

    # print zmprov commands to STDOUT
    printZmprov($users);
    exit 0;
}


sub readConfig {
    my $config = YAML::XS::LoadFile("$FindBin::Bin/../etc/zimbra-bulk-create.yml");
    if ($opt{debug}) {
        say "### Config ###";
        say Dumper $config;
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

    if ($opt{debug}) {
        # print entries in debug mode
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

    my $groupfilter = $config->{LDAP}->{groupfilter};
    my $userfilter  = $config->{LDAP}->{userfilter};

    my ($ldap, $mesg);
    my $uids = ();
    my $users = ();
    my $filterUsersByGroup = '';

    if ($groupfilter) {
        $groupfilter =~ s|_GROUPFILTER_|$opt{ldapgroupfilter}|;
        ($ldap, $mesg) = __searchInLDAP( $config->{LDAP}->{server},
                                         $config->{LDAP}->{binduser},
                                         $config->{LDAP}->{bindpassword},
                                         $config->{LDAP}->{groupbase},
                                         $groupfilter );

        # action loop for all group entries from LDAP
        for my $node (0 .. ($mesg->entries - 1)) {
            my $entry = $mesg->entry($node);
            my $cn = $entry->get_value('cn');
            my @uniquemembers = $entry->get_value('uniquemember');
            if ($opt{debug}) {
                say "## Result ##";
                for (@uniquemembers) {
                    say "# $cn: $_";
                }
            }
            for my $dn (@uniquemembers) {
                my @path = split /,/, $dn;
                my $uid = shift @path;
                push @{$uids}, $uid;
            }
        }
        $filterUsersByGroup .= "(|";
        for my $uid (@{$uids}) {
            $filterUsersByGroup .= "($uid)"
        }
        $filterUsersByGroup .= ")";
    }

    $userfilter =~ s|_FROMGROUPFILTER_|$filterUsersByGroup|;
    $userfilter =~ s|_USERFILTER_|$opt{ldapuserfilter}|;

    if ($opt{debug}) {
        say "### FILTER ###";
        say Dumper { groupfilter => $groupfilter, userfilter => $userfilter };
    }

    ($ldap, $mesg) = __searchInLDAP(    $config->{LDAP}->{server},
                                        $config->{LDAP}->{binduser},
                                        $config->{LDAP}->{bindpassword},
                                        $config->{LDAP}->{userbase},
                                        $userfilter );

    # action loop for all user entries
    for my $node (0 .. ($mesg->entries - 1)) {
        my $entry = $mesg->entry($node);
        my $uid = $entry->get_value('uid');
        if ($opt{debug}) {
            say "# LDAP user: $uid";
        }
        for my $key (sort keys $config->{LDAP}->{specialfields}) {
            my $value = $entry->get_value($config->{LDAP}->{specialfields}->{$key});
            $users->{$uid}->{specialfields}->{$key} = $value;
        }
        for my $key (sort keys $config->{LDAP}->{copykeyvaluefields}) {
            my $value = $entry->get_value($config->{LDAP}->{copykeyvaluefields}->{$key});
            $users->{$uid}->{copykeyvaluefields}->{$key} = $value;
        }
    }

    $ldap->unbind();

    if ($opt{debug}) {
        say "### Users ###";
        say Dumper $users;
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
        $create .= "\t" . 'displayname ' . "\"$users->{$user}->{specialfields}->{gn} $users->{$user}->{specialfields}->{sn}\"" . ' \\' . "\n";
        $create .= "\t" . 'zimbraPasswordMustChange FALSE' . ' \\' . "\n";
        for my $k (keys $users->{$user}->{copykeyvaluefields}) {
            $create .= "\t" . $k . ' ' . $users->{$user}->{copykeyvaluefields}->{$k} . ' \\' ."\n";
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

     --man              show man-page and exit
 -h, --help             display this help and exit
     --version          output version information and exit

     --debug            prints debug messages

     --ldapgroupfilter  extend the LDAP group query search with given arguments
     --ldapuserfilter   extend the LDAP user query search with given arguments

     --defaultdomain    Default Domain for each created user

     --defaultcosid     COS ID of the default COS


=head1 DESCRIPTION

This script will query an LDAP for group and user attributes. The LDAP
search amount can be filtered by the filter argument in the config file
and also with LDAP group and/or user filter arguments on the command line.

zimbra-build-create will print an zmprov output which can be inserted
to the Zimbra system with

    zmprov -f zimbra-bulk-create.txt

=head2 Example

Example configuration file:

Example content for ./etc/zimbra-bulk-create.yml

    LDAP:
        server:       ldap://ldap.example.com:389
        binduser:     cn=ldapsearchuser,dc=example,dc=com
        bindpassword: secret

        groupbase:    o=Providers,dc=example,dc=com
        groupfilter:  (&(objectClass=groupOfUniqueNames)_GROUPFILTER_)

        userbase:     cn=Users,dc=example,dc=com
        userfilter:   (&(objectClass=Users)_FROMGROUPFILTER__USERFILTER_)

        specialfields:
            username:   uid
            alias:      mail
            password:   plainpassword
            gn:         givenname
            sn:         sn

        copykeyvaluefields:
            gn:               givenname
            sn:               sn
            c:                c
            zimbraPrefLocale: lang

Run bulk creation script:

  ./bin/zimbra-bulk-create.pl \
       --defaultdomain=example.com \
       --defaultcosid=ABCD-EFG-1234 \
       --ldapgroupfilter '(cn=BulkCreateUsers)'
       --ldapuserfilter  '(uid=rplessl)'

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
 2014-05-01 rp Improved API and capability to filter by LDAP groups

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
