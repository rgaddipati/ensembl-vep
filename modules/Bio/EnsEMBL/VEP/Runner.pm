=head1 LICENSE

Copyright [1999-2016] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut


=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

 Questions may also be sent to the Ensembl help desk at
 <http://www.ensembl.org/Help/Contact>.

=cut

# EnsEMBL module for Bio::EnsEMBL::VEP::Runner
#
#

=head1 NAME

Bio::EnsEMBL::VEP::Runner - runner class for VEP

=cut


use strict;
use warnings;

package Bio::EnsEMBL::VEP::Runner;

use base qw(Bio::EnsEMBL::VEP::BaseVEP);

use Storable qw(freeze thaw);
use IO::Socket;
use IO::Select;

use Bio::EnsEMBL::Utils::Scalar qw(assert_ref);
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::VEP::Utils qw(get_time);
use Bio::EnsEMBL::VEP::Constants;
use Bio::EnsEMBL::VEP::Config;
use Bio::EnsEMBL::VEP::Parser;
use Bio::EnsEMBL::VEP::InputBuffer;
use Bio::EnsEMBL::VEP::OutputFactory;
use Bio::EnsEMBL::VEP::AnnotationSourceAdaptor;

# don't assert refs
$Bio::EnsEMBL::Utils::Scalar::ASSERTIONS = 0;

# don't use rearrange
$Bio::EnsEMBL::Utils::Argument::NO_REARRANGE = 1;

# avoid using transfer
$Bio::EnsEMBL::Variation::TranscriptVariationAllele::NO_TRANSFER = 1;

# has our own new method, does not use BaseVEP's
# since this is the class users will be instantiating
sub new {
  my $caller = shift;
  my $class = ref($caller) || $caller;
  
  # initialise self
  my $self = bless {}, $class;

  # get a config object
  $self->{_config} = Bio::EnsEMBL::VEP::Config->new(@_);

  return $self;
}

# dispatcher/runner for all initial setup from config
sub init {
  my $self = shift;

  return 1 if $self->{_initialized};

  # setup DB connection
  $self->setup_db_connection();

  # get all annotation sources
  my $annotation_sources = $self->get_all_AnnotationSources();

  # setup FASTA file DB
  my $fasta_db = $self->fasta_db();

  my $buffer = $self->get_InputBuffer();

  $self->post_setup_checks();

  return $self->{_initialized} = 1;
}

# run
# sub run {
#   my $self = shift;

#   $self->init();

#   my $input_buffer = $self->input_buffer;

#   while(my $vfs = $input_buffer->next()) {
#     last unless scalar @$vfs;

#     foreach my $as(@{$self->get_all_AnnotationSources}) {
#       $as->annotate_InputBuffer($input_buffer);
#     }
#   }
# }

sub next_output_line {
  my $self = shift;

  my $output_buffer = $self->{_output_buffer} ||= [];

  return shift @$output_buffer if @$output_buffer;

  $self->init();

  if($self->param('fork')) {
    push @$output_buffer, @{$self->_forked_buffer_to_output($self->get_InputBuffer)};
  }
  else {
    push @$output_buffer, @{$self->_buffer_to_output($self->get_InputBuffer)};
  }

  return @$output_buffer ? shift @$output_buffer : undef;
}

sub _buffer_to_output {
  my $self = shift;
  my $input_buffer = shift;

  my @output;
  my $vfs = $input_buffer->next();

  if($vfs && scalar @$vfs) {
    my $output_factory = $self->get_OutputFactory;

    foreach my $as(@{$self->get_all_AnnotationSources}) {
      $as->annotate_InputBuffer($input_buffer);
    }
      
    $input_buffer->finish_annotation;

    push @output, @{$output_factory->get_all_lines_by_InputBuffer($input_buffer)};
  }

  return \@output;
}

sub _forked_buffer_to_output {
  my $self = shift;
  my $buffer = shift;

  # get a buffer-sized chunk of VFs to split and fork on
  my $vfs = $buffer->next();
  return [] unless $vfs && scalar @$vfs;

  my $fork_number = $self->param('fork');
  my $buffer_size = $self->param('buffer_size');
  my $delta = 0.5;
  my $minForkSize = 50;
  my $maxForkSize = int($buffer_size / (2 * $fork_number));
  my $active_forks = 0;
  my (@pids, %by_pid);
  my $sel = IO::Select->new;

  # loop while variants in @$vfs or forks running
  while(@$vfs or $active_forks) {

    # only spawn new forks if we have space
    if($active_forks <= $fork_number) {
      my $numLines = scalar @$vfs;
      my $forkSize = int($numLines / ($fork_number + ($delta * $fork_number)) + $minForkSize ) + 1;

      $forkSize = $maxForkSize if $forkSize > $maxForkSize;

      while(@$vfs && $active_forks <= $fork_number) {

        # create sockets for IPC
        my ($child, $parent);
        socketpair($child, $parent, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or throw("ERROR: Failed to open socketpair: $!");
        $child->autoflush(1);
        $parent->autoflush(1);
        $sel->add($child);

        # readjust forkSize if it's bigger than the remaining buffer
        # otherwise the input buffer will read more from the parser
        $forkSize = scalar @$vfs if $forkSize > scalar @$vfs;
        my @tmp = splice(@$vfs, 0, $forkSize);

        # fork
        my $pid = fork;
        if(!defined($pid)) {
          throw("ERROR: Failed to fork\n");
        }
        elsif($pid) {
          push @pids, $pid;
          $active_forks++;
        }
        elsif($pid == 0) {
          $self->_run_forked($buffer, \@tmp, $forkSize, $parent);
        }
      }
    }

    # read child input
    while(my @ready = $sel->can_read()) {
      my $no_read = 1;

      foreach my $fh(@ready) {
        $no_read++;

        my $line = join('', $fh->getlines());
        next unless $line;
        $no_read = 0;

        my $data = thaw($line);
        next unless $data && $data->{pid};

        # data
        $by_pid{$data->{pid}} = $data->{output} if $data->{output};

        # stderr
        $self->warning_msg($data->{stderr}) if $data->{stderr};

        # finish up
        $sel->remove($fh);
        $fh->close;
        $active_forks--;

        throw("ERROR: Forked process(es) died\n".$data->{die}) if $data->{die};
      }

      # read-through detected, DIE
      throw("\nERROR: Forked process(es) died\n") if $no_read;

      last if $active_forks < $fork_number;
    }
  }

  waitpid($_, 0) for @pids;

  # sort data by dispatched PID order and return
  return [map {@{$by_pid{$_} || []}} @pids];
}

sub _run_forked {
  my $self = shift;
  my $buffer = shift;
  my $vfs = shift;
  my $forkSize = shift;
  my $parent = shift;

  # redirect and capture STDERR
  $self->config->{warning_fh} = *STDERR;
  close STDERR;
  my $stderr;
  open STDERR, '>', \$stderr;

  # reset the input buffer and add a chunk of data to its pre-buffer
  # this way it gets read in on the following next() call
  # which will be made by _buffer_to_output()
  $buffer->{buffer_size} = $forkSize;
  $buffer->reset_buffer();
  push @{$buffer->pre_buffer}, @$vfs;

  # force reinitialise FASTA
  # the XS code doesn't seem to like being forked
  delete $self->config->{_fasta_db};

  # we want to capture any deaths and accurately report any errors
  # so we use eval to run the core chunk of the code (_buffer_to_output)
  my $output;
  eval {
    # for testing
    $self->warning_msg('TEST WARNING') if $self->{_test_warning};
    throw('TEST DIE') if $self->{_test_die};

    # the real thing
    $output = $self->_buffer_to_output($buffer);
  };

  # send everything we've captured to the parent process
  # PID allows parent process to re-sort output to correct order
  print $parent freeze({
    pid => $$,
    output => $output,
    stderr => $stderr,
    die => $@,
  });

  # some plugins may cache stuff, check for this and try and
  # reconstitute it into parent's plugin cache
  # foreach my $plugin(@{$config->{plugins}}) {
  #   next unless defined($plugin->{has_cache});

  #   # delete unnecessary stuff and stuff that can't be serialised
  #   delete $plugin->{$_} for qw(config feature_types variant_feature_types version feature_types_wanted variant_feature_types_wanted params);
  #   print PARENT $$." PLUGIN ".ref($plugin)." ".encode_base64(freeze($plugin), "\t")."\n";
  # }

  # # tell parent about stats
  # print PARENT $$." STATS ".encode_base64(freeze($config->{stats}), "\t")."\n" if defined($config->{stats});

  exit(0);
}

sub post_setup_checks {
  my $self = shift;

  # disable HGVS if no FASTA file found and it was switched on by --everything
  if(
    $self->param('hgvs') &&
    $self->param('offline') &&
    $self->param('everything') &&
    !$self->fasta_db
  ) {
    $self->status_msg("INFO: Disabling --hgvs; using --offline and no FASTA file found\n");
    $self->param('hgvs', 0);
  }
  
  # offline needs cache, can't use HGVS
  if($self->param('offline')) {
    unless($self->fasta_db) {
      die("ERROR: Cannot generate HGVS coordinates in offline mode without a FASTA file (see --fasta)\n") if $self->param('hgvs');
      die("ERROR: Cannot check reference sequences without a FASTA file (see --fasta)\n") if $self->param('check_ref')
    }
    
    # die("ERROR: Cannot do frequency filtering in offline mode\n") if defined($config->{check_frequency}) && $config->{freq_pop} !~ /1kg.*(all|afr|amr|asn|eur)/i;
    die("ERROR: Cannot map to LRGs in offline mode\n") if $self->param('lrg');
  }
    
  # warn user DB will be used for SIFT/PolyPhen/HGVS/frequency/LRG
  if($self->param('cache')) {
        
    # these two def depend on DB
    foreach my $param(grep {$self->param($_)} qw(lrg check_sv)) {
      $self->status_msg("INFO: Database will be accessed when using --$param");
    }

    # and these depend on either DB or FASTA DB
    unless($self->fasta_db) {
      foreach my $param(grep {$self->param($_)} qw(hgvs check_ref)) {
        $self->status_msg("INFO: Database will be accessed when using --$param");
      }
    }
        
    # $self->status_msg("INFO: Database will be accessed when using --check_frequency with population ".$config->{freq_pop}) if defined($config->{check_frequency}) && $config->{freq_pop} !~ /1kg.*(all|afr|amr|asn|eur)/i;
  }

  return 1;
}

sub setup_db_connection {
  my $self = shift;

  return if $self->param('offline');

  # doing this inits the registry and DB connection
  my $reg = $self->registry();

  # check assembly
  if(my $db_assembly = $self->get_database_assembly) {

    my $config_assembly = $self->param('assembly');

    throw(
      "ERROR: Assembly version specified by --assembly (".$config_assembly.
      ") and assembly version in coord_system table (".$db_assembly.") do not match\n".
      (
        $self->param('host') eq 'ensembldb.ensembl.org' ?
        "\nIf using human GRCh37 add \"--port 3337\"".
        " to use the GRCh37 database, or --offline to avoid database connection entirely\n" :
        ''
      )
    ) if $config_assembly && $config_assembly ne $db_assembly;

    # update to database version
    $self->param('assembly', $db_assembly);

    if(!$self->param('assembly')) {
      throw("ERROR: No assembly version specified, use --assembly [version] or check the coord_system table in your core database\n");
    }
  }

  # update species, e.g. if user has input "human" we get "homo_sapiens"
  $self->species($reg->get_alias($self->param('species')));

  return 1;
}

sub get_all_AnnotationSources {
  my $self = shift;

  if(!exists($self->{_annotation_sources})) {
    my $asa = Bio::EnsEMBL::VEP::AnnotationSourceAdaptor->new({config => $self->config});
    $self->{_annotation_sources} = $asa->get_all;
  }

  return $self->{_annotation_sources};
}

sub get_Parser {
  my $self = shift;

  if(!exists($self->{parser})) {

    # user given input data as string (REST)?
    if(my $input_data = $self->param('input_data')) {
      open IN, '<', \$input_data;
      $self->param('input_file', *IN);
    }

    $self->{parser} = Bio::EnsEMBL::VEP::Parser->new({
      config            => $self->config,
      format            => $self->param('format'),
      file              => $self->param('input_file'),
      valid_chromosomes => $self->get_valid_chromosomes,
    })
  }

  return $self->{parser};
}

sub get_InputBuffer {
  my $self = shift;

  if(!exists($self->{input_buffer})) {
    $self->{input_buffer} = Bio::EnsEMBL::VEP::InputBuffer->new({
      config => $self->config,
      parser => $self->get_Parser
    });
  }

  return $self->{input_buffer};
}

sub get_OutputFactory {
  my $self = shift;

  if(!exists($self->{output_factory})) {
    $self->{output_factory} = Bio::EnsEMBL::VEP::OutputFactory->new({
      config      => $self->config,
      format      => $self->param('output_format'),
      header_info => $self->get_output_header_info,
    });
  }

  return $self->{output_factory};
}

sub get_output_header_info {
  my $self = shift;

  if(!exists($self->{output_header_info})) {

    my $info = {
      time          => get_time,
      vep_version   => $Bio::EnsEMBL::VEP::Constants::VERSION,
      api_version   => $self->registry->software_version,
      input_headers => $self->get_Parser->headers,
    };

    if(my $mca = $self->get_adaptor('core', 'MetaContainer')) {
      $info->{db_name} = $mca->dbc->dbname;
      $info->{db_host} = $mca->dbc->host;
      $info->{db_version} = $mca->get_schema_version;
    }

    foreach my $as(@{$self->get_all_AnnotationSources}) {
      my $as_info = $as->info;
      $info->{version_data}->{$_} ||= $as_info->{$_} for keys %$as_info;
      $info->{cache_dir} ||= $as->dir if $as->can('dir');
    }

    $self->{output_header_info} = $info;
  }

  return $self->{output_header_info};
}

sub get_valid_chromosomes {
  my $self = shift;

  if(!exists($self->{valid_chromosomes})) {

    my %valid = ();

    foreach my $as(@{$self->get_all_AnnotationSources}) {
      next unless $as->can('get_valid_chromosomes');
      $valid{$_} = 1 for @{$as->get_valid_chromosomes};
    }

    $self->{valid_chromosomes} = [sort keys %valid];
  }

  return $self->{valid_chromosomes};
}

1;