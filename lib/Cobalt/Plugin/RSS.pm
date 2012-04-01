package Cobalt::Plugin::RSS;
our $VERSION = '0.05';

use Data::Dumper;

use Cobalt::Common;

use File::Spec;

use XML::RSS::Feed;

sub new { bless { }, shift }

sub core { 
  my ($self, $core) = @_;
  return $self->{CORE} = $core if $core and ref $core;
  return $self->{CORE}
}

sub announce {
  my ($self, $feedname, $context, $channel) = @_;
  my $core = $self->core;
  return unless $feedname and $context and $channel;
  my $announceheap = $core->State->{HEAP}->{RSSPLUG}->{ANN};
  push(@{ $announceheap->{$feedname}->{$context} }, $channel);
  return $channel
}

sub get_ann_hash {
  my ($self, $feedname) = @_;
  my $core = $self->core;
  return unless $feedname;
  my $announceh = $core->State->{HEAP}->{RSSPLUG}->{ANN}->{$feedname};
  return $announceh
}

sub track {
  my ($self, $feedname, $url, $delay) = @_;
  my $core = $self->core;
  return unless $feedname and $url;
  $delay = 120 unless $delay;
  my $pheap = $core->State->{HEAP}->{RSSPLUG};
  return if exists $pheap->{FEEDS}->{$feedname};
  $pheap->{FEEDS}->{$feedname} = {
    url    => $url,
    delay  => $delay,
    HasRun => 0,
  };
  return $feedname
}

sub list_feed_names {
  my ($self) = @_;
  my $core = $self->core;
  my $pheap = $core->State->{HEAP}->{RSSPLUG};
  my @feeds = keys %{$pheap->{FEEDS}};
  return @feeds
}

sub get_feed_meta {
  my ($self, $feedname) = @_;
  return unless $feedname;
  my $core = $self->core;
  my $pheap = $core->State->{HEAP}->{RSSPLUG};
  my $item = $pheap->{FEEDS}->{$feedname};
  return $item
}

sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;
  $self->core($core);
  
  ## FIXME move all this shit back to internals
  $core->State->{HEAP}->{RSSPLUG} = { ANN => {}, FEEDS => {} };
  
  my $pcfg = $core->get_plugin_cfg($self);

  my $feeds = $pcfg->{Feeds};
  
#  $core->log->info( Dumper $feeds );
  
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
      
      my $delay = $feeds->{$feedname}->{Delay};

      $core->log->info("$feedname -> $uri ($delay)");

      $self->track($feedname, $uri, $delay)
        or $core->log->warn("Could not add $feedname: track() failed");
            
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
        $core->log->info(
          "Announcing feed $feedname to $count channels on $context"
        );
        $self->announce($feedname, $context, $_)
          for @{ $sendto->{$context} };
      } ## CONTEXT
    
    } ## FEED
  } else {
    $core->log->warn(
      "There are no RSS feeds configured; doing nothing.",
      "You may want to inspect this plugin's Config: file.",
      "For an example, see: perldoc Cobalt::Plugin::RSS"
    );
  }

  unless ($self->{RSSAGG}) {
    $core->log->emerg("No RSSAggregator instance?");
    croak "Could not initialize RSSAggregator"
  }

  ## FIXME set up and kickstart delay pool
  
  my $count = $self->list_feed_names;
  $core->log->info("Loaded - $VERSION - watching $count feeds");
  $core->plugin_register( $self, 'SERVER',
    [
      ## FIXME timer to check delay pool
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


sub _feed {
  ## FIXME convert to operate on responses
  my ($self, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];
  my $core = $self->core;

  my $feed  = $_[ARG1]->[0];
  my $title = $feed->title;
  my $name  = $feed->name;

  my $feedmeta = $self->get_feed_meta($name);
  my $sendto   = $self->get_ann_hash($name);
  
  unless ($feedmeta && $sendto) {
    $core->log->warn("BUG - missing feedmeta/sendto for $name");
    return
  }
  
  unless ($feedmeta->{HasRun}) {
    $feedmeta->{HasRun} = 1;
#    $feed->init_headlines_seen;
    $core->log->info("Skipping $name - initial headline feed");
    return
  }
  
  HEAD: for my $headline ( $feed->late_breaking_news ) {
    my $this_line = $headline->headline;
    my $this_url  = $headline->url;
    my $this_headline = "$name: $this_line ( $this_url )";

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
