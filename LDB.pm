#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;

require 5.005;
our $version = 1.0;

package LDB;

=head1 LDB

=cut

#------------------------------
#        Default values
#------------------------------

=pod

=head2 Default values

Default values are specified. You can specify some of them by command
line options. String ${HOME} will be replaced with environment
variable $HOME.

=over 4

=item B<lucie_wc>

I<Local> location of Lucie working copy.

Default is F<$HOME/lucie_github>.

=item B<ldb_wc>

I<Local> location of LDB working copy.

Default is F<$HOME/L4>.

=item B<secret_file>

I<Local> location of secret file which contains passwords.

Default is F<$HOME/lucie_github/env.enc>.

=item B<remote_ldb_repository_type>

VCS type of remote LDB repository.

Default is F<Subversion>.

=item B<remote_ldb_repository>

I<Remote> location of LDB repository.

Default is F<svn+ssh://intri@www.intrigger.jp/home/intri/SVN/L4>.

=back


=cut

my $defaults = {
                lucie_wc => q|${HOME}/lucie_github/|,
                ldb_wc =>   q|${HOME}/L4|,
                secret_file => q|${HOME}/lucie_github/env.enc|,
                remote_ldb_repository_type => q|Subversion|,
                remote_ldb_repository => q|svn+ssh://intri@www.intrigger.jp/home/intri/SVN/L4|,
               };

#**************************************************
#                     Templates
#**************************************************

=head2 Templates

=over 4

=item B<SQL templates>

Only one SQL template C<select * from host where name="NAME"> is used
for now. We can easily integrate node data and attribute names by
getting the list of column names by C<ldb attrs>.

=item B<Command-line templates>

Command-line templates are templates of Lucie. We need two types of
command-line templates.

=over 4

=item B<Node template>

Template of configuration of each node. This contains B<node name>,
B<MAC address> for installation(I<PXE-bootable>), B<storage
configuration file> for L<setup-storage(8)>, B<IP address> for
installation, and B<netmask> for installation.

=item B<Global template>

Whole command line template of Lucie. C<${LINE_TMPLS}> will be
replaced with Node templates that have been replaced, each of which is
quoted as B<"Node template" \E<lt>CRE<gt>>

C<BREAK_FLAG> is set only when executed for just one node and
B<--nobreak> optios not specified.

C<LINUX_KERNEL> and C<ARCHITECTURE> options are selected properly.

=back

=back

=cut

#------------------------------
#        SQL templates
#------------------------------

my $select_sql = q|select * from host |;
# SQL to select a node by name
my $node_select_sql = $select_sql . q| where name="${NAME}"|;

#------------------------------
#        CL templates
#------------------------------
our $node_tmpl = q|${name} --mac ${install_mac} --storage-conf ${storage_conf_type} --ip-address ${install_ipaddr} --netmask ${install_netmask}|;
my $global_tmpl = <<'END';
#!/bin/sh

# ********************************************************
# **************** Lucie Installer Script ****************
# *** Check if this script is correct on your own risk ***
# ********************************************************

${LUCIE_WC}/node install \
${LINE_TMPLS}
--source-control ${REMOTE_LDB_REPOSITORY_TYPE} \
--ldb-repository ${REMOTE_LDB_REPOSITORY_LOCATION} \
--verbose \
--linux-image ${LINUX_KERNEL} \
--architecture ${ARCHITECTURE} \
${BREAK_FLAG} \
--secret ${SECRET_FILE}
END


#------------------------------
#        Public Methods
#------------------------------

=head2 Public methods

=over 4

=cut

=item new()

Create a new LDB object. This does not use arguments, so just call
C<new LDB> or C<LDB-E<gt>new>.

=cut

sub new($) {
  my $class = shift;
  my $self = {};
  $self->{nodes} = {};
  $self->{verbose} = 0; # Verbose level
  $self->{status} = {};
  return bless $self, $class;
}

=item getattr()

Execute C<ldb attrs> command and know the order of columns in LDB
database.

This returns L</Status> object.

=cut

sub getattr($) {
  my $self = shift;
  my $retval;
  return Status->new(0, "Not configured yet") if !$self->{status}->{configure};
  $retval = exec_cmd(join " ", $self->ldb_cmd, "attrs");
  return $retval if $retval->isError;
  $self->{attrs} = $retval->message;
  $self->{status}->{getattr} = 1;
  return Status->new(1);
}

=item getinfo()

Execute C<ldb sql> command and know the data for each node in LDB
database. It internally creates L</Node> object for each node to
manage information.

This returns L</Status> object.

=cut

sub getinfo($) {
  my $self = shift;
  my $status;
  return Status->new(0, "No getattr") if !$self->{status}->{getattr};
  foreach my $node ($self->nodes) {
    my $sql = $self->node_sql_line($node);
    my $result = $self->exec_sql($sql);
    return $result if ($result->isError);
    my $n = Node->new({attrs=>$self->attrs, info=>$result->message});
    $self->add_node($n);
  }
  $self->{status}->{getinfo} = 1;
  return Status->new(1);
}

=item configure(\%hash)

Configure LDB object mainly with command line options. It checks file,
directory, and executable program existence whose location it know at
this time.

This returns L</Status> object.

=cut

sub configure($\%) {
  my $self = shift;
  my $href = shift;
  my $status;
  ### Flags
  $self->{verbose} = 1 if defined $href->{verbose};
  my $opt_break = defined $href->{nobreak} ? 0 : 1; # only by cmdline option
  $self->{nopreserve} = defined $href->{nopreserve} ? 1 : 0;
  ### Args
  # Target nodes
  my $nodelist = expand_cluster($href->{nodelist});
  # Exclude
  #print $href->{exclude};
  my @a = ();
  for my $n (@$nodelist) {
    push @a, $n if !grep /$n/, @{expand_cluster($href->{exclude})};
  }
  $self->{nodelist} = \@a;
  return Status->new(0, "Target node not specified.") if (scalar @{$self->{nodelist}} == 0);
  # Break Flag
  $self->{break} = ($opt_break and scalar @{$self->{nodelist}} == 1) ? 1 : 0;
  # Secret file
  $self->{secret_file} = $href->{"secret-file"} || $defaults->{"secret_file"};
  $self->{secret_file} = templatize($self->{secret_file});
  if (!defined $href->{"nocheck-secret-file"}) {
    $status = check_file_existence($self->{secret_file});
    return $status if $status->isError;
  }
  # LDB repository type
  $self->{remote_ldb_type} = $href->{"remote-ldb-type"} || $defaults->{"remote_ldb_repository_type"};
  # LDB repository location
  $self->{remote_ldb_location} = $href->{"remote-ldb-location"} || $defaults->{"remote_ldb_repository"};
  # LDB working copy location
  $self->{ldb_wc} = $href->{"ldb-wc"} || $defaults->{"ldb_wc"};
  $self->{ldb_wc} = templatize($self->{ldb_wc});
  $status = check_directory_existence($self->{ldb_wc});
  return $status if $status->isError;
  # Lucie working copy location
  $self->{lucie_wc} = $href->{"lucie-wc"} || $defaults->{"lucie_wc"};
  $self->{lucie_wc} = templatize($self->{lucie_wc});
  $status = check_directory_existence($self->{lucie_wc});
  return $status if $status->isError;
  # LDB database file
  $self->{db_file} = $href->{"db-file"} || undef;
  if (defined $self->{db_file}) {
    $self->{db_file} = templatize($self->{lucie_wc});
    $status = check_directory_existence($self->{lucie_wc});
    $status = check_executable_existence($self->{lucie_wc} . 'bin/ldb');
    return $status if $status->isError;
  }
  #print Data::Dumper->Dump([$href]) if $self->isDebug;
  $self->{status}->{configure} = 1;
  return Status->new(1);
}

=item check_consistency()

Check all of values are consistent. it checks only arch for now.

This returns L</Status> object.

=cut

sub check_consistency {
  my $self = shift;
  my $status;
  my @target = qw(arch);
  for my $t (@target) {
    my @params = map {$self->{nodes}->{$_}->get($t)} $self->nodes;
    $status = is_array_consistent(@params);
    if (!$status){
      return Status->new(0, "$t not consistent: @params");
    };
    $self->{consistent}->{$t} = $params[0];
  }
  return Status->new(1);
}

=item generate()

Fill all of template and create whole command for Lucie. You can get
Lucie command by L</command> after calling this method.

This returns L</Status> object.

=cut

sub generate($) {
  my $self = shift;
  my $tmpl = $global_tmpl;
  my $tp = {};
  my $status;
  my $n;
  my @lines = ();
  for my $name (sort keys %{$self->{nodes}}) {
    $n = $self->{nodes}->{$name};
    $status = $n->lucie_line({ldb_wc => $self->{ldb_wc},
                              nopreserve => $self->{nopreserve}});
    return $status if $status->isError;
    push @lines, $status->message;
  }
  $tp->{LINE_TMPLS} = join "\n", map qq|"$_" \\|, @lines;
  $tp->{LUCIE_WC} = $self->{lucie_wc};
  $tp->{SECRET_FILE} = $self->{secret_file};
  $tp->{REMOTE_LDB_REPOSITORY_TYPE} = $self->{remote_ldb_type};
  $tp->{REMOTE_LDB_REPOSITORY_LOCATION} = $self->{remote_ldb_location};
  $tp->{BREAK_FLAG} = $self->{break} ? q|--break| : q||;
  $tp->{ARCHITECTURE} = $self->architecture($self->{consistent}->{arch});
  $tp->{LINUX_KERNEL} = $self->install_kernel($self->{consistent}->{arch});
  while ($tmpl =~ /\${([A-Z_]+?)}/) {
    my $t = $1;
    my $replacement = $tp->{$t};
    print $t if !defined $replacement;
    $tmpl =~ s/\${$t}/$replacement/;
  }
  $self->{command} = $tmpl;
  return Status->new(1);
}

=item command()

Returns command string of Lucie.

=cut

sub command($) {
  my $self = shift;
  return $self->{command};
}

=item isDebug()

Returns true if this runs in debug mode.

=cut

sub isDebug($) {
  my $self = shift;
  return $self->{verbose};
}

=item isDebug()

Print debug messages.

=cut

sub debug($) {
  my $self = shift;
  print STDERR Data::Dumper->Dump([$self]);
}

=back

=cut

#------------------------------
#        Private Methods
#------------------------------

# ldb attrs accessor. comma-separated
sub attrs($) {
  my $self = shift;
  return $self->{attrs};
}

# node name array accessor.
sub nodes($) {
  my $self = shift;
  return @{$self->{nodelist}};
}

# add hash $self->{nodes}->{NAME} = NODEobject
sub add_node($$) {
  my $self = shift;
  my $node = shift;
  $self->{nodes}->{$node->get("name")} = $node;
}

# nodename-node hash accessor.
sub nodehash($) {
  my $self = shift;
  return $self->{nodes};
}

# execute SQL command
sub exec_sql($$) {
  my $self = shift;
  my $sql = shift;
  my $sql_cmd = $self->create_sql_cmd($sql);
  return exec_cmd($sql_cmd);
}

# fill SQL template with node name.
sub node_sql_line($$) {
  my $self = shift;
  my $nodename = shift;
  my $tmp = $node_select_sql;
  $tmp =~ s/\${NAME}/$nodename/;
  return $tmp;
}

# LDB commandline.
sub ldb_cmd($) {
  my $self = shift;
  my $ldb_cmd = $self->{ldb_wc} . '/bin/ldb';
  return $ldb_cmd;
}

# Create final SQL command with LDB.
sub create_sql_cmd($$) {
  my $self = shift;
  my $sql = shift;
  my $ldb_cmd = $self->ldb_cmd;
  $sql =~ s/'/\\'/g;
  $ldb_cmd .= ' --db-file=' . $self->{db_file} if defined $self->{db_file};
  $ldb_cmd .= ' sql ';
  $ldb_cmd .= qq|'$sql'|;
  return $ldb_cmd;
}

# Select appropriate architecture name from the architecture.
sub architecture ($$) {
  my $self = shift;
  my $arch = shift;
  my $arch_hash = {
                   x86_64 => "amd64",
                   i686 => "i386",
                  };
  return $arch_hash->{$arch};
}

# Select appropriate Linux kernel package name from the architecture.
sub install_kernel ($$) {
  my $self = shift;
  my $arch = shift;
  my $arch_hash = {
                   x86_64 => "linux-image-amd64",
                   i686 => "linux-image-686",
                  };
  return $arch_hash->{$arch};
}

#------------------------------
#        Utility Subroutines
#------------------------------

sub check_file_existence($) {
  my $path = shift;
  if (-f $path) {
    Status->new(1);
  } else {
    Status->new(0, "File $path not exists");
  }
}

sub check_directory_existence($) {
  my $path = shift;
  if (-d $path) {
    Status->new(1);
  } else {
    Status->new(0, "Directory $path not exists");
  }
}

sub check_executable_existence($) {
  my $path = shift;
  if (-x $path) {
    Status->new(1);
  } else {
    Status->new(0, "Executable file $path not exists");
  }
}

sub templatize {
  my $str = shift;
  # Replacements
  my $home = $ENV{HOME};
  $str =~ s/\${HOME}/$home/;
  return $str;
}

sub is_array_consistent (@) {
  my @a = @_;
  my @b = sort @a;
  return "$b[0]" eq "$b[$#b]";
}

# GXP-like node expansion
sub expand_cluster($) {
  my $arg = shift;
  return [] if !defined $arg;
  my @_nodes = split /\s+/, $arg;
  my @list = ();
  for my $nodes (@_nodes) {
    if ($nodes =~ /(.+)\[\[(.+)-(.+)\]\]/) {
      my $prefix = $1;
      my $head = $2;
      my $tail = $3;
      my $d = length $head;
      for my $x ($head .. $tail) {
        my $node = sprintf "%s%0*d", $prefix, $d, $x;
        push @list, $node;
      }
    } else {
      push @list, $nodes;
    }
  }
  return \@list;
}

sub exec_cmd ($) {
  my $cmd = shift;
  my $handle;
  my $errmsg;
  open $handle, $cmd . " | " or goto cantpipe;
  $errmsg = $!;
  my $retval = <$handle>;
  close $handle;
  goto failed if (!defined $retval);
  return Status->new(1, $retval);
 cantpipe:
  return Status->new(0, "Can't open pipe: $errmsg");
 failed:
  return Status->new(0, "Failed to execute command($cmd): $errmsg $?");
}

#**************************************************
#                   Node Class
#**************************************************

package Node;

=head1 Node

Express one node.

=cut

=head2 Public methods

=over 4

=cut

=item B<new(\%hash)>

Constructor. With hash, maintain hash C<$self-E<gt>{info}>. Argument hash
must contain keys C<attrs>, and C<info>, each of which is
C<|>-separated string.

Example:

    my $node = new Node({attrs=>"name|install_mac|...", info=>"hongo100|00:11:22:33:44:55|..."});

=cut

sub new {
  my $class = shift;
  my $hash = shift;
  my $self = {};
  $self->{info} = {};
  my $attrs = $hash->{attrs};
  my $infoline = $hash->{info};
  my @attrs = split /\|/, $attrs;
  my @info = split /\|/, $infoline;
  for my $i (0 .. scalar @attrs - 1) {
    chomp $attrs[$i];
    chomp $info[$i];
    $self->{info}->{$attrs[$i]} = $info[$i];
  }
  return bless $self, $class;
}

=item B<get($attr)>

Accessor to a Node attribute.

Example:

    $node->get("install_mac");

=cut

sub get($$) {
  my $self = shift;
  my $attr = shift;
  return $self->{info}->{$attr};
}

=item B<lucie_line(\%opt)>

Create Lucie command-line option for the node. Argument %opt should
have keys L<ldb_wc> and L<nopreserve>, representing the location of
LDB local location and flag of C<preserve_reinstall> option,
respectively.

This method returns a L</Status> object. On success, the state is
success and message should have the command-line option. Otherwise the
state is an error.

Example:

    $ret = $node->lucie_line({ldb_wc=>"/home/...", nopreserve=>0, });
    if ($ret->isError) {
      .. Error handle ..
    } else {
      #success
      $line = $ret->message;
    }

=cut

sub lucie_line($$) {
  my $self = shift;
  my $opt = shift;
  my $tmpl = $LDB::node_tmpl;
  while ($tmpl =~ /\${([a-z_]+?)}/) {
    my $t = $1;
    my $replacement = $self->get($t);
    if ($t eq 'storage_conf_type') {
      $replacement = $opt->{ldb_wc} . "/lucie_github/storage/" . $replacement;
      $replacement .= "_nopreserve" if $opt->{nopreserve};
      return Status->new(0, "Storage conf file $replacement does not exist")
        if (!-f $replacement);
    }
    $tmpl =~ s/\${$t}/$replacement/;
  }
  $self->{lucie_line} = $tmpl;
  return Status->new(1, $tmpl);
}

=back

=cut

#**************************************************
#                   Status Class
#**************************************************

package Status;

=head1 Status

Status class.

=cut

=head2 Public methods

=cut

=over 4

=cut

=item new($state, [$message])

Constructor. On success $state is non-zero value.

=cut

sub new {
  my $class = shift;
  my $self = {};
  my $status = shift;
  my $message = shift;
  $self->{status} = $status;
  $self->{message} = $message;
  return bless $self, $class;
}

=item message()

Returns message of the status.

=cut

sub message {
  my $self = shift;
  return $self->{message};
}

=item isError()

Returns true if the state is erroneous, otherwise returns false.

=cut

sub isError {
  my $self = shift;
  return $self->status ? 0 : 1;
}

#------------------------------
#       Private methods
#------------------------------

# status accessor.
sub status {
  my $self = shift;
  return $self->{status};
}

1;

