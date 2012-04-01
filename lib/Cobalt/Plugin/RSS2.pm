package Cobalt::Plugin::RSS;
our $VERSION = '0.06';

use Cobalt::Common;

use File::Spec;

use XML::RSS::Feed;

sub new {
  my $class = shift;
  my $self  = {
    HEAP => {
      POOL  => {},
      ANN   => {},
      FEEDS => {},
    },
  };
  
  bless $self, $class;
  return $self
}

sub core {
  my ($self, $core) = @_;
  return $self->{CORE} = $core if $core and ref $core;
  return $self->{CORE}
}

sub pending {
  ## pending()
  ## get timer pool
  my ($self) = @_;
  return $self->{HEAP}->{POOL};
}

sub announce {
  ## announce($name, $context, $channel)
  ## add new announce for feed/context/channel
  my ($self, $feedname, $context, $channel) = @_;
  my $core = $self->core;
  return unless $feedname and $context and $channel;
  my $a_heap = $self->{HEAP}->{ANN};
  push(@{$a_heap->{$feedname}->{$context}}, $channel);
  return $channel
}

sub get_announce {
  ## get_announce($name, $context)
  ## get arrayref of channels for this feed/context
  my ($self, $feedname, $context) = @_;
  my $core = $self->core;
  return unless $feedname;
  my $a_heap = $self->{HEAP}->{ANN};
  return $a_heap->{$feedname}->{$context} if $context;
  return $a_heap->{$feedname}
}

sub track {
  ## track($name, $url, $delay)
  ## add new feed to {FEEDS}
  my ($self, $feedname, $url, $delay) = @_;
  my $core = $self->core;
  return unless $feedname and $url;
  $delay = 120 unless $delay;
  my $p_heap = $self->{HEAP}->{FEEDS};
  return if exists $p_heap->{$feedname};
  $p_heap->{$feedname} = {
    url   => $url,
    delay => $delay,
    obj   => undef,
    HasRun => 0,
  };
  return $feedname
}

sub list_feed_names {
  ## list_feed_names()
  ## returns list of {FEEDS} keys
  my ($self) = @_;
  my $core = $self->core;
  my $p_heap = $self->{HEAP}->{FEEDS};
  my @feeds = keys %$p_heap;
  return @feeds
}

sub get_feed_meta {
  ## get_feed_meta($name)
  ## returns {FEEDS} element w/ url and delay
  my ($self, $feedname) = @_;
  return unless $feedname;
  my $core = $self->core;
  my $p_heap = $self->{HEAP}->{FEEDS};
  return $p_heap->{$feedname}
}

sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;
  $self->core($core);

  my $pcfg = $core->get_plugin_cfg($self);
  my $feeds = $pcfg->{Feeds};
  
  if ($feeds && ref $feeds eq 'HASH' && keys %$feeds) {
    FEED: for my $feedname (keys %$feeds) {
      my $thisfeed = $feeds->{$feedname};
      
      my $url = $thisfeed->{URL};
      unless ($url) {
        ## FIXME warn
        next FEED
      }
      
      my $annto = $thisfeed->{AnnounceTo};
      unless ($annto && ref $annto eq 'HASH') {
        ## FIXME warn
        next FEED
      }
      
      my $delay = $thisfeed->{Delay} || 120;
      
      $self->track($feedname, $url, $delay)
        or $core->log->warn("Could not add $feedname: track() failed");
        
      CONTEXT: for my $context (keys %$annto) {
        my $thiscont = $annto->{$context};
        unless (ref $thiscont eq 'ARRAY') {
          ## FIXME warn
          next CONTEXT
        }
        
        $self->announce($feedname, $context, $_)
          for @$thiscont;
      } ## CONTEXT
        
    } ## FEED
  } else {
    ## FIXME warn
  }

  $core->plugin_register( $self, 'SERVER', 
    [
      'rssplug_check_timer_pool',
      'rssplug_got_resp',
    ],
  );
  
  ## FIXME set up XML::RSS::Feed
  ## FIXME kickstart timer pool
  $core->log->info("Loaded - $VERSION");  
  return PLUGIN_EAT_NONE
}
  

sub Cobalt_unregister {
  my ($self, $core) = splice @_, 0, 2;
  $core->log->info("Unloaded");
  return PLUGIN_EAT_NONE
}

sub Bot_rssplug_check_timer_pool {
  my ($self, $core) = splice @_, 0, 2;
  
  my $pool = $self->pending;
  
  ## FIXME check timestamps on pool (keyed on name?)
  ## if ts is up, execute _request, schedule new
    
  return PLUGIN_EAT_NONE
}

sub Bot_rssplug_got_resp {
  my ($self, $core) = splice @_, 0, 2;
  my $response = ${ $_[1] };
  my $args     = ${ $_[2] };
  my ($feedname) = @$args;

  if ($response->is_success) {
    my $feedmeta = $self->get_feed_meta($feedname);
    my $handler  = $feedmeta->{obj};
    ## FIXME if no $handler, _create_feed and set init headlines ?
    ## FIXME
  } else {
    ## FIXME warn
    return PLUGIN_EAT_NONE
  }  
  ## FIXME grab response
  ##  grab name tag
  ##  feed content to get_feed_meta($name)->{obj}->parse
  ##  check HasRun? should be able to just handle it internally 
  ##    (via XML::RSS::Feed)
  ##  yield off messages (handler?)  
  
  return PLUGIN_EAT_NONE
}

sub _create_feed {
  ## _create_feed($name)
  ## create (and return) new XML::RSS::Feed based on get_feed_meta
  my ($self, $feedname) = @_;
  my $core = $self->core;

  my $feedmeta = $self->get_feed_meta($feedname);

  $feedmeta->{tmpdir} = File::Spec->tmpdir
    unless $feedmeta->{tmpdir};
    
  if ( my $rss = XML::RSS::Feed->new(%$feedmeta) ) {
    $feedmeta->{obj} = $rss;
  } else {
    $core->log->warn(
      "Could not create XML::RSS::Feed obj for $feedname"
    );
  }
  
  return $feedmeta->{obj}  
}

sub _request {
  my ($self, $feedname) = @_;
  my $core = $self->core;

  my $feedmeta = $self->get_feed_meta($feedname);
  
  unless ($core->Provided->{www_request}) {
    $core->log->warn("You seem to be missing Cobalt::Plugin::WWW!");
    return PLUGIN_EAT_NONE
  }

  ## send request tagged w/ feedname  
  my $url = $feedmeta->{url};
  my $req = HTTP::Request->new( 'GET', $url );
  $core->send_event( 'www_request',
    $req,
    'rssplug_got_resp',
    [ $feedname ],
  );
  
  return 1
}

1;
