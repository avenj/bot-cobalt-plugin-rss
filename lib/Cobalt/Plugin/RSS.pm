package Cobalt::Plugin::RSS;
our $VERSION = '0.04';

use Cobalt::Common;

use File::Spec;

use POE qw/Component::RSSAggregator/;

sub new { bless {}, shift }

sub core { 
  my ($self, $core) = @_;
  return $self->{CORE} = $core if $core and ref $core;
  return $self->{CORE}
}

sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;
  $self->core($core);
  
  $self->{ANNOUNCE} = {};
  $self->{FEEDS}    = {};
  
  my $pcfg = $core->get_plugin_cfg($self);

  my $feeds = $pcfg->{Feeds};
  
  if ($feeds && ref $feeds eq 'HASH' && keys %$feeds) {
    FEED: for my $feedname (keys %$feeds) {
    
      my $uri = $feeds->{$feedname}->{URL};
      unless ($uri) {
        $core->log->warn(
          "Could not add feed $feedname: missing URL directive.",
          "Check your configuration."
        );
        next FEED
      }
    
      my $sendto = $feeds->{$feedname}->{AnnounceTo};
      unless ($sendto && ref $sendto eq 'HASH') {
        $core->log->warn(
          "Could not add feed $feedname: invalid AnnounceTo directive.",
          "Check your configuration."
        );
        next FEED      
      }
      
      my $delay = $feeds->{$feedname}->{Delay} || 120;
      ## FEEDS{$feedname} = {
      ##   url   => ...
      ##   delay => ...
      ##   HasRun => BOOL
      ## }
      $self->{FEEDS}->{$feedname} = {
        HasRun => 0,
        url => $uri,
        delay => $delay,
      };
      
      ## sets up a hash mapping:
      ##  ANNOUNCE{$feedname} = { $context => [ @channels ], }     
      CONTEXT: for my $context (keys %$sendto) {
        unless (ref $sendto->{$context} eq 'ARRAY') {
          $core->log->warn(
            "Configured AnnounceTo Context $context is not a list.",
            "Check your configuration."
          );
          next CONTEXT
        }
        my $count = @{ $sendto->{$context} };
        $core->log->debug(
          "Announcing feed $feedname to $count channels on $context"
        );
        push(@{ $self->{ANNOUNCE}->{$feedname}->{$context} },
          @{ $sendto->{$context} }
        );
      }
    
    }
  } else {
    $core->log->warn(
      "There are no RSS feeds configured; doing nothing.",
      "You may want to inspect this plugin's Config: file.",
      "For an example, see: perldoc Cobalt::Plugin::RSS"
    );
  }

  $core->log->debug("Spawning session to handle RSS");
  POE::Session->create(
    object_states => [
      $self => [
        '_start',
        '_feed',
      ],
    ],
  );
  
  unless ($self->{RSSAGG}) {
    $core->log->emerg("No RSSAggregator instance?");
    croak "Could not initialize RSSAggregator"
  }

  $core->log->info("Loaded - $VERSION");
  $core->plugin_register( $self, 'SERVER',
    [
#      'public_cmd_rssaddfeed',
#      'public_cmd_rssdelfeed',
    ],
  );
  return PLUGIN_EAT_NONE
}

sub Cobalt_unregister {
  my ($self, $core) = splice @_, 0, 2;
  $self->{RSSAGG}->shutdown;
  $core->log->info("Unloaded");
  return PLUGIN_EAT_NONE
}


## POE

sub _start {
  my ($self, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];
  my $core = $self->core;
  my $poe_alias = 'rssagg'.$core->get_plugin_alias($self);

  $self->{RSSAGG} = POE::Component::RSSAggregator->new(
    alias => $poe_alias,
    callback => $session->postback("_feed"),
    tmpdir => File::Spec->tmpdir(),
  );

  my $feeds = $self->{FEEDS};
  for my $feedname (keys %$feeds) {
    my $thisfeed = $feeds->{$feedname};
    $kernel->post($poe_alias, 'add_feed', 
      {
        name  => $feedname,
        delay => $thisfeed->{delay},
        url   => $thisfeed->{url},
      },
    );
  }
}

sub _feed {
  my ($self, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];
  my $core = $self->core;

  my $feed  = $_[ARG1]->[0];
  my $title = $feed->title;
  my $name  = $feed->name;
  
  my $feedmeta = $self->{FEEDS}->{$name};
  my $sendto   = $self->{ANNOUNCE}->{$name};
  
  unless ($feedmeta->{HasRun}) {
    ++$feedmeta->{HasRun};
    $feed->init_headlines_seen;
    return
  }
  
  HEAD: for my $headline ( $feed->late_breaking_news ) {
    my $this_line = $headline->headline;
    my $this_url  = $headline->url;
    my $this_headline = "$name: $this_line ($this_url)";

    CONTEXT: for my $context (keys %$sendto) {
      my $irc = $core->get_irc_obj($context) || next CONTEXT;
      
      CHAN: for my $chan ( @{ $sendto->{$context} } ) {
        $core->log->debug("dispatching to $chan ($context)")
          if $core->debug > 1;
        ## FIXME next CHAN if not present on chan
        $core->send_event( 'send_message', $context, $chan,
          color('bold', "RSS:")." $this_headline",
        );
      } ## CHAN
    
    } ## CONTEXT
    
  } ## HEAD
}

1;
__END__

=pod

=head1 NAME

Cobalt::Plugin::RSS - Monitor RSS feeds via IRC

=head1 SYNOPSIS

  ## In plugins.conf:
  RSS:
    Module: Cobalt::Plugin::RSS
    Config: plugins/rss.conf

  ## Requires properly configured rss.conf
  !plugin load RSS

=head1 DESCRIPTION

Monitors an arbitrary number of RSS feeds, reporting new headlines to 
configured contexts/channels.

=head1 EXAMPLE CONF

  ---
  ## example etc/plugins/rss.conf
  Feeds:
    MyFeed:
      URL: 'http://rss.slashdot.org/Slashdot/slashdot'
      Delay: 300
      AnnounceTo:
        Main:
          - '#eris'
          - '#otw'
      
        ParadoxIRC:
          - '#perl'

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

L<http://www.cobaltirc.org>

=cut
