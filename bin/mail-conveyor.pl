#!/usr/bin/env perl
use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../thirdparty/lib/perl5";

use 5.010;

use Getopt::Long qw(:config posix_default no_ignore_case auto_version);
use Pod::Usage;
use Data::Dumper;

use File::Basename;
use File::Temp qw(tempfile);
use Net::LDAP;
use Term::ReadKey;
use YAML::XS;

our $VERSION = '1.7';

# parse options
my %opt = ();

# main loop
sub main {
    my @mandatory = (qw(oldserver=s newserver=s popruxidb=s));
    GetOptions(\%opt, qw(help|h man noaction|no-action|n debug ldap|l ldapuserfilter=s ldapgroupfilter=s userfile|f cyrusmigration cyrusfiles=s domain=s oldpassword=s newpassword=s olduser=s newuser=s resetmigrated), @mandatory ) or exit(1);

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
        $users = fetchUserFromLDAP($config);
    } else {
        $users = fetchUserFromFile($config);
    }

    # ask proceed with selected users
    proceedWithSelectedUsers($users);

    # special mode for revert LDAP field changing
    if ($opt{resetmigrated}) {
        say STDERR "Reset migrated users now";
        for my $user (keys $users) {
            $filter = $config->{LDAP}->{userfilter};
            $filter =~ s|_FROMGROUPFILTER_||;
            $filter =~ s|_USERFILTER_|(uid=$user)|;
            writeLDAPAttribute($config, $filter, $config->{LDAP}->{premigration});
        }
        exit 0;
    }

    if ($opt{cyrusmigration}) {
        # fetch data from cyrus and push configuration settings to Zimbra
        my ($fh, $filename) = tempfile();
        getZimbraProvisioningCommands($users, $fh, $filename);
        activateZimbraProvisioningCommands($config, $fh, $filename);
        File::Temp::cleanup();
    }

    # sync emails
    for my $user (keys $users) {
        say "Syncing Mails for User: $user";
        $filter = $config->{LDAP}->{userfilter};
        $filter =~ s|_FROMGROUPFILTER_||;
        $filter =~ s|_USERFILTER_|(uid=$user)|g;
        writeLDAPAttribute($config, $filter, $config->{LDAP}->{migration});
        syncEmailsImap($users->{$user},1); # with delete
        matchPopUid($users->{$user});
        writeLDAPAttribute($config, $filter, $config->{LDAP}->{postmigration});
        syncEmailsImap($users->{$user}); # without delete
    }
    exit 0;
}


sub readConfig {
    my $config = YAML::XS::LoadFile("$FindBin::Bin/../etc/mail-conveyor.yml");
    if ($opt{debug}) {
        say STDERR "### Config ###";
        say STDERR Dumper $config;
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
        say STDERR "### Users ###\n", Dumper $users;
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

    if ($opt{debug}) {
        # print entries in debug mode
        say STDERR "Nodes selected in LDAP:";
        if ($mesg->entries == 0) {
            say STDERR "--> no entries found in LDAP <--";
        }
        if ($mesg->entries > 1) {
            say STDERR "--> " . $mesg->entries." entries found in LDAP <--";
        }
    }return ($ldap, $mesg);

}

sub fetchUserFromLDAP {
    my $config = shift;

    my $groupfilter = $config->{LDAP}->{groupfilter};
    # apply command line filter arguments
    $opt{ldapgroupfilter} = $opt{ldapgroupfilter} // '';

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
                say STDERR "## Result ##";
                for (@uniquemembers) {
                    say STDERR "# $cn: $_";
                }
            }
            for my $dn (@uniquemembers) {
                my @path = split /,/, $dn;
                my $uid = shift @path;
                push @{$uids}, $uid;
            }
        }
    }

    # only process <= 100 entries in one round
    while (@$uids){
        my $uidCount = 0;
        my $filterUsersByGroup = '(|';
        while (my $uid = shift @$uids) {
            $filterUsersByGroup .= "($uid)";
            last if $uidCount++ > 100;
        }
        $filterUsersByGroup .= ")";

        my $userfilter  = $config->{LDAP}->{userfilter};
        # apply command line filter arguments
        $opt{ldapuserfilter}  = $opt{ldapuserfilter}  // '';
        $userfilter =~ s|_FROMGROUPFILTER_|$filterUsersByGroup|;
        $userfilter =~ s|_USERFILTER_|$opt{ldapuserfilter}|;

        if ($opt{debug}) {
            say STDERR "### FILTER ###";
            say STDERR Dumper { groupfilter => $groupfilter, userfilter => $userfilter };
        }

        ($ldap, $mesg) = __searchInLDAP(    $config->{LDAP}->{server},
                                            $config->{LDAP}->{binduser},
                                            $config->{LDAP}->{bindpassword},
                                            $config->{LDAP}->{userbase},
                                            $userfilter );

        # action loop for all entries
        for my $node (0 .. ($mesg->entries - 1)) {
            my $entry = $mesg->entry($node);
            my $uid = $entry->get_value('uid');
            if ($opt{debug}) {
                say STDERR "# LDAP user: $uid";
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
    }
    $ldap->unbind();

    if ($opt{debug}) {
        say STDERR "### Users ###";
        say STDERR Dumper $users;
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
                                        $config->{LDAP}->{userbase},
                                        $filter );

    # action loop for all entries
    for my $node (0 .. ($mesg->entries - 1)) {
        my $entry = $mesg->entry($node);
        my $dn = $entry->dn;
        my $uid = $entry->get_value('uid');
        for my $key (keys $modification) {
            my $ret = $ldap->modify ( $dn, replace => { $key => $modification->{$key} } );
            say STDERR "$uid : " . $ret->error;
        }
    }
    $ldap->unbind();
}

sub syncEmailsImap {
    my $user = shift;
    my $delete = shift;
    my $fh;
    open($fh,
         '-|',
         "$FindBin::Bin/../thirdparty/bin/imapsync",
         '--host1',      $user->{oldserver}   ? $user->{oldserver}   : $opt{oldserver},
         '--user1',      $user->{username}    ? $user->{username}    : $opt{oldusername},
         '--password1',  $user->{oldpassword} ? $user->{oldpassword} : $opt{oldpassword},
         '--host2',      $user->{newserver}   ? $user->{newserver}   : $opt{newserver},
         '--user2',      $user->{username}    ? $user->{username}    : $opt{newusername},
         '--password2',  $user->{newpassword} ? $user->{newpassword} : $opt{newpassword},
         $delete ? ('--delete2') : (),
     ) or do { say STDERR "Cannot Sync with imapsync"; };

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
         '--olduser',   $user->{username}    ? $user->{username}    : $opt{oldusername},
         '--oldpass',   $user->{oldpassword} ? $user->{oldpassword} : $opt{oldpassword},
         '--newserver', $user->{newserver}   ? $user->{newserver}   : $opt{newserver},
         '--newuser',   $user->{username}    ? $user->{username}    : $opt{newusername},
         '--newpass',   $user->{newpassword} ? $user->{newpassword} : $opt{newpassword},
         '--dbfile',    $opt{popruxidb}
     ) or do { say STDERR "Cannot sync UIDLs"; };

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
    open($cyrus2zmprov,
          '-|',
          @args
      ) or do { say STDERR "Cannot run cyrus2zmprov script"; };
    while (<$cyrus2zmprov>) {
        print $_;
        print $temp_fh $_;
    }
    close($cyrus2zmprov);
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
      ) or do { say STDERR "Cannot run transfer data to Zimbra host"; };
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
     ) or do { say STDERR "Cannot call remote zmprov"; };
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
        '/usr/bin/env unlink',
        "$temp_filename_dir/$temp_filename_name"
    );
    open($fh,
         '-|',
         @ssh_args
     ) or do { say STDERR "Cannot unlink file $temp_filename"; };
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

     --man              show man-page and exit
 -h, --help             display this help and exit
     --version          output version information and exit

     --debug            prints debug messages

     --noaction         noaction mode

 -l  --ldap             ldap mode
     --ldapgroupfilter  extend the LDAP group query search with given arguments
     --ldapuserfilter   extend the LDAP user query search with given arguments

 -f  --userfile         userfile mode

     --oldserver        old server address
     --newserver        new server address

     --propruxidb       path and name to popruxi database

     --cyrusmigration   enables cyrus2zmprov / Cyrus -> Zimbra migration
     --cyrusfiles       path to cyrus files for cyrus2zmprov
     --domain           email domain for cyrus2zmprov

=head1 DESCRIPTION

This tool migrate users from one email system to another and integrates
the toolboxes and scripts of imapsync and popruxi.

This script will get an amount of users from LDAP or from a flatfile
and will process the email migration for each user.

Users fetched from LDAP groups will be divided in 100 user chunks, so
the LDAP server can handle this not to long requests.

=head2 Example

Example configuration file:

Example content for ./etc/mail-conveyor.yml

    LDAP:
        server:       ldap://ldap.example.com
        binduser:     cn=ldapsearchuser,dc=example,dc=com
        bindpassword: secret

        adminbinduser:     cn=ldapadmin,dc=example,dc=com
        adminbindpassword: verysecret

        groupbase:    o=Providers,dc=example,dc=com
        groupfilter:  (&(objectClass=groupOfUniqueNames)_GROUPFILTER_)

        userbase:     cn=Users,dc=example,dc=com
        userfilter:   (&(objectClass=Users)_FROMGROUPFILTER__USERFILTER_)

        userkeyfields:
            username:    ldapkey1
            newpassword: _fixed_value_from_commandline_input_
            oldpassword: ldapkey3

        premigration:
            ldapkey1: value10
            ldapkey2: value20

        migration:
            ldapkey1: value40
            ldapkey2: value30

        postmigration:
            ldapkey1: value10
            ldapkey1: value30

    Users:
        username1: {
            username:    username1,
            alias:       alias1@example.com
            oldpassword: _fixed_value_from_commandline_input_,
            newpassword: new
        }
        username2: {
            username:    username2,
            alias:       alias2@example.com
            oldpassword: old,
            newpassword: new
        }

Run mail conveyor script:

    $ ./bin/mail-conveyor.pl \
      --oldserver oldserver.example.com \
      --newserver newserver.example.com \
      --popruxidb ./var/uidmatcher.db \
      --debug \
      --ldap \
      --ldapgroupfilter '(cn=MigrationGroup)' \
      --ldapuserfilter '(|(uid=user1)(uid=user2))' \
      --cyrusmigration \
      --domain example.com \
      --cyrusfiles /home/mailsync/cyrus_data


=head3 Revert migration mode

The mail conveyor has a revert mode which resets the LDAP configration
to the old configuration. This allows in tests to rerun the migration.

    $ ./bin/mail-conveyor.pl \
      --oldserver oldserver.example.com \
      --newserver newserver.example.com \
      --debug \
      --ldap \
      --ldapgroupfilter '(cn=MigrationGroup)' \
      --ldapuserfilter '(|(uid=user1)(uid=user2))' \
      --resetmigrated

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
