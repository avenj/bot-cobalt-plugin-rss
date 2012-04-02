package Cobalt::Plugin::RSS;
our $VERSION = '0.08';

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
  ## get_announce($name [, $context ])
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
  my ($self, $feedname, $url, $delay, $spacing) = @_;
  my $core = $self->core;
  return unless $feedname and $url;
  $delay = 120 unless $delay;
  $spacing = 5 unless $spacing;
  my $p_heap = $self->{HEAP}->{FEEDS};
  return if exists $p_heap->{$feedname};
  $p_heap->{$feedname} = {
    hasrun => 0,
    url   => $url,
    delay => $delay,
    space => $spacing,
  };
  
  ## Can create our XML::RSS:Feed now (requires proper hash above):
  $p_heap->{obj} = $self->_create_feed($feedname);

  ## add to timer pool
  my $pool = $self->pending;
  $pool->{$feedname} = {
    LastRun => 0,
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
        $core->log->warn(
          "Could not add feed $feedname: missing URL directive",
        );
        next FEED
      }
      
      my $annto = $thisfeed->{AnnounceTo};
      unless ($annto && ref $annto eq 'HASH') {
        $core->log->warn(
          "Could not add feed $feedname: invalid AnnounceTo directive",
        );
        next FEED
      }
      
      my $delay = $thisfeed->{Delay} || 120;
      my $spacing = $thisfeed->{Spaced} || 5;
      $self->track($feedname, $url, $delay, $spacing)
        or $core->log->warn("Could not add $feedname: track() failed");
        
      CONTEXT: for my $context (keys %$annto) {
        my $thiscont = $annto->{$context};
        unless (ref $thiscont eq 'ARRAY') {
          $core->log->warn(
            "Configured AnnounceTo directive not a list.",
            "Check your configuration."
          );
          next CONTEXT
        }
        
        $self->announce($feedname, $context, $_)
          for @$thiscont;
      } ## CONTEXT
        
    } ## FEED
  } else {
    $core->log->warn(
      "There are no RSS feeds configured; doing nothing.",
      "You may want to inspect this plugin's Config: file.",
      "See perldoc Cobalt::Plugin::RSS",
    );
  }

  $core->plugin_register( $self, 'SERVER', 
    [
      'rssplug_check_timer_pool',
      'rssplug_got_resp',
    ],
  );
  
  $core->timer_set( 6,
    { Event => 'rssplug_check_timer_pool', },
    'RSSPLUG_CHECK_POOL'
  );
  my $count = $self->list_feed_names;
  $core->log->info("Loaded - $VERSION - watching $count feeds");  
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
  
  ## check timestamps on pool (keyed on name)
  ## if ts is up, execute _request, schedule new
  for my $feedname (keys %$pool) {
    my $feedmeta  = $self->get_feed_meta($feedname)
                    || return PLUGIN_EAT_NONE;
    my $thistimer = $pool->{$feedname};
    my $lastts    = $thistimer->{LastRun} || 0;
    my $delay     = $feedmeta->{delay};
    
    if (time - $lastts >= $delay) {
      $self->_request($feedname);
      $thistimer->{LastRun} = time;
    }
  }

  $core->timer_set( 6,
    { Event => 'rssplug_check_timer_pool', },
    'RSSPLUG_CHECK_POOL'
  );
    
  return PLUGIN_EAT_NONE
}

sub Bot_rssplug_got_resp {
  my ($self, $core) = splice @_, 0, 2;
  my $response = ${ $_[1] };
  my $args     = ${ $_[2] };
  my ($feedname) = @$args;

  if ($response->is_success) {
    my $feedmeta = $self->get_feed_meta($feedname)
                   || return PLUGIN_EAT_NONE;
    my $handler  = $feedmeta->{obj};
    
    if ( $handler->parse($response->content) ) {
      $self->_send_announce($feedname, $handler);
    }
  } else {
    $core->log->warn(
      "Unsuccessful HTTP request: $feedname: ".$response->status
    );
    return PLUGIN_EAT_NONE
  }  
  
  return PLUGIN_EAT_NONE
}

sub _send_announce {
  my ($self, $name, $handler) = @_;
  my $core = $self->core;
  
  my $title = $handler->title;
  
  my $feedmeta = $self->get_feed_meta($name);
  
  my $a_heap = $self->get_announce($name);

  unless ($feedmeta->{hasrun}) {
    $feedmeta->{hasrun} = 1;
    $handler->init_headlines_seen(1);
    ## for some reason init_headlines_seen sometimes fails ...
    (undef) = $handler->late_breaking_news;
    return
  }

  my $spacing = $feedmeta->{space};
  my $spcount = 0;
  HEAD: for my $headline ( $handler->late_breaking_news ) {
    my $this_line = $headline->headline;
    my $this_url  = $headline->url;
    my $str = "RSS: "
            .color('bold', $name)
            .": $this_line ( $this_url )" ;

    CONTEXT: for my $context (keys %$a_heap) {
      my $irc = $core->get_irc_object($context) || next CONTEXT;
      $core->timer_set( 1 + $spcount,
        {
         Type => 'msg',
         Context => $context,
         Target  => $_,
         Text    => $str,
        },
      ) for @{$a_heap->{$context}};
    } ## CONTEXT
    $spcount += $spacing;
  } ## HEAD
}

sub _create_feed {
  ## _create_feed($name)
  ## create (and return) new XML::RSS::Feed based on get_feed_meta
  my ($self, $feedname) = @_;
  my $core = $self->core;

  my $feedmeta = $self->get_feed_meta($feedname);

  $feedmeta->{tmpdir} = File::Spec->tmpdir
    unless $feedmeta->{tmpdir};
    
  my %feedopts = (
    name => $feedname,
    url  => $feedmeta->{url},
    delay  => $feedmeta->{delay},
    tmpdir => File::Spec->tmpdir(),
    init_headlines_seen => 0,
  );
  
  if ( my $rss = XML::RSS::Feed->new(%feedopts) ) {
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
      ## If your feed publishes a lot in one go, add delays:
      Spaced: 10
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
