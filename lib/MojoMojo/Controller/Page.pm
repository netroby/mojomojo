package MojoMojo::Controller::Page;

use strict;
use base 'Catalyst::Controller';
use IO::Scalar;
use URI;
use Text::Context;
use HTML::Strip;
use Data::Page;
use Data::Dumper;
use WWW::Google::SiteMap;

=head1 NAME

MojoMojo::Controller::Page - Page controller

=head1 SYNOPSIS

=head1 DESCRIPTION

This controller is the main juice of MojoMojo. it handles all the
actions related to wiki pages. Actions are redispatched to this
controller based on a Regex controller in the main MojoMojo class.

Every private action here expects to have a page path in args. They
can be called with urls like "/page1/page2.action".

=head1 ACTIONS

=head2  view (.view)

This is probably the most common action in MojoMojo. A lot of the
other actions redispatch to this one. It will prepare the stash
for page view, and set the template to view.tt, unless another is
already set.

It also takes an optional 'rev' parameter, in which case it will
load the provided revision instead.

=cut

sub page_not_found : Private {
    my ( $self, $c ) = @_;
    $c->res->status('404');
    $c->stash->{message} = $c->loc("The requested URL (x) was not found",
                               $c->stash->{pre_hacked_uri});
    $c->stash->{template} = 'message.tt';
}

sub robots : Private {
    my ( $self, $c ) = @_;
    $c->res->status('200');
    $c->res->header( 'Content-Type', 'text/plain' );
    $c->stash->{template} = 'robots.txt';
}

sub sitemap : Private {
    my ( $self, $c ) = @_;
    $c->res->status('200');
    $c->res->header( 'Content-Type', 'application/x-gzip' );
    $c->stash->{template} = 'sitemap.gz';
}

sub view : Global {
    my ( $self, $c, $path ) = @_;

    return $c->forward('robots')
      if ( $c->stash->{path} eq "robots.txt" );
    return $c->forward('sitemap')
      if ( $c->stash->{path} eq "sitemap.gz" );

    my $stash = $c->stash;
    $stash->{template} ||= 'page/view.tt';

    $c->forward('inline_tags');
    $c->stash->{render} = 'highlight'
      if $c->req->referer && $c->req->referer =~ /.edit/;

    my ( $path_pages, $proto_pages, $id ) =
      @$stash{qw/ path_pages proto_pages id /};

    # we should always have at least "/" in path pages. if we don't,
    # we must not have had these structures in the stash

    return $c->forward('suggest')
      if $proto_pages && @$proto_pages;

    my $page = $stash->{'page'};

    my $good_url;
    if ($c->config->{use_directory}) {
        if ($page->has_child) {
            $good_url=$c->stash->{page}->path.'/';
        }
        else {
            $good_url=$c->stash->{page}->path;
        }

        if ( "/" . $c->stash->{path} ne $good_url ){
                return $c->forward('page_not_found') ;
        }
    }


    my $user;
    if ( $c->pref('check_permission_on_view') ne""
         ? $c->pref('check_permission_on_view')
         : $c->config->{'permissions'}{'check_permission_on_view'} ) {
        if ( $c->user_exists() ) { $user = $c->user->obj; }
        $c->log->info('Checking permissions') if $c->debug;

        my $perms = $c->check_permissions( $stash->{'path'}, $user );
        if ( !$perms->{'view'} ) {
            $stash->{'message'} =
              $c->loc( 'Permission Denied to view x', $page->name );
            $stash->{'template'} = 'message.tt';
            return;
        }
    }

    my $content;

    my $rev = $c->req->params->{rev};
    if ( $rev && defined $page->content_version ) {
        $content = $c->model("DBIC::Content")->find(
            {
                page    => $page->id,
                version => $rev
            }
        );
        $stash->{rev} = ( defined $content ? $content->version : undef );
        unless ( $stash->{rev} ) {
            $stash->{message} =
              $c->loc( 'No such revision for ', $page->name );
            $stash->{template} = 'message.tt';
        }
    }
    else {
        $content = $page->content;
        unless ($content) {
            $c->detach('/pageadmin/edit');

        }
        $stash->{rev} = $content->version;
    }
    $stash->{content} = $content;

}

=head2 search (.search)

This action is called as .search on the current page when the user
performs a search.  The user can choose whether or not to search
the entire site or a subtree starting from the current page.

=cut

sub search : Global {
    my ( $self, $c ) = @_;

    my $stash = $c->stash;

    # number of search results to show per page
    my $results_per_page = 10;

    my $page = $c->stash->{page};
    $stash->{template} = 'page/search.tt';

    my $q           = $c->req->params->{q}           || $c->stash->{query};
    my $search_type = $c->req->params->{search_type} || "subtree";
    $stash->{query}       = $q;
    $stash->{search_type} = $search_type;

    my $strip = HTML::Strip->new;

    my $results = [];

# for subtree searches, add the path info to the query, replacing slashes with X
    my $real_query = $q;    # this is for context matching later
    if ( $search_type eq "subtree" ) {
        my $fixed_path = $page->path;
        $fixed_path =~ s/\//X/g;
        $q = "path:$fixed_path* AND " . $q;
    }

    my $hits = $c->model('Search')->search($q);
    my %results_hash;
    while ( my $hit = $hits->fetch_hit_hashref ) {
        $hit->{path} =~ s/X/\//g;
        my ($path_pages) =
          $c->model('DBIC::Page')->path_pages( $hit->{path} );
        my $page = $path_pages->[ @$path_pages - 1 ];

        # skip search result depending on permissions
        my $user;
        if ( $c->pref('check_permission_on_view') ne""
             ? $c->pref('check_permission_on_view')
             : $c->config->{'permissions'}{'check_permission_on_view'} ) {
            if ( $c->user_exists() ) { $user = $c->user->obj; }
            my $perms = $c->check_permissions( $page->path, $user );
            next unless $perms->{'view'};
        }

        # add a snippet of text containing the search query
        my $content = $strip->parse( $page->content->formatted($c) );
        $strip->eof;

# FIXME: Bug? Some snippet text doesn't get displayed properly by Text::Context
        my $snippet =
          Text::Context->new( $content, split( / /, $real_query ) );

        # Convert Kinosearch hit score from decimal to percent.
        # my $score = sprintf( "%.0f", $hit->{score} * 1000 );

        # Store goods to be used in search results listing
        # NOTE: $page->path is '/' for app root,
        # but $c->request->path is empty for app root.
        my $title_base_nodes;
        if ( $page->path ne '/' ) {
            ( $title_base_nodes ) =
              $page->path =~ m{(.*/).*$};
            $title_base_nodes =~ s{^/}{};
            $title_base_nodes =~ s{/}{ > }g;
        }
        $results_hash{ $hit->{path} } = {
            snippet             => $snippet->as_html,
            page                => $page,
            score               => $hit->{score},
            title_base_nodes    => $title_base_nodes,
        };

    }

    # Order hits by score.
    my @results;
    foreach my $hit_path (
        sort { $results_hash{$b}->{'score'} <=> $results_hash{$a}->{'score'} }
        keys %results_hash
      )
    {
        push @results, $results_hash{$hit_path};
    }
    $results = \@results;
    my $result_count = scalar @$results;
    if ($result_count) {

# Paginate the results
# This is done even with even 1 page of results so the template doesn't need to do
# two separate things
        my $pager = Data::Page->new;
        $pager->total_entries($result_count);
        $pager->entries_per_page($results_per_page);
        $pager->current_page( $c->req->params->{p} || 1 );

        if ( $result_count > $results_per_page ) {

            # trim down the results to just this page
            @$results = $pager->splice($results);
        }

        $c->stash->{pager} = $pager;
        my $last_page = ( $pager->last_page > 10 ) ? 10 : $pager->last_page;
        $c->stash->{pages_to_link} = [ 1 .. $last_page ];
        $c->stash->{results}       = $results;
        $c->stash->{result_count}  = $result_count;
    }
}

=head2 print

this action is the same as the view action, with another template

=cut

sub print : Global {
    my ( $self, $c, $page ) = @_;
    $c->stash->{template} = 'page/print.tt';
    $c->forward('view');
}

sub inline : Global {
    my ( $self, $c, $page ) = @_;
    $c->stash->{template} = 'page/inline.tt';
    $c->forward('view');
}


=head2 inline_tags (.inline_tags)

Tag list for the bottom of page views.

=cut

sub inline_tags : Global {
    my ( $self, $c, $highlight ) = @_;
    $c->stash->{template} ||= 'page/tags.tt';
    $c->stash->{highlight} = $highlight;
    my $page = $c->stash->{page};
    if ( $c->user_exists ) {
        my @tags = $page->others_tags( $c->user->obj->id );
        $c->stash->{others_tags} = [@tags];
        @tags = $page->user_tags( $c->user->obj->id );
        $c->stash->{taglist} = ' ' . join( ' ', map { $_->tag } @tags ) . ' ';
        $c->stash->{tags}    = [@tags];
    }
    else {
        $c->stash->{others_tags} = [ $page->tags_with_counts ];
    }
}

=head2 list (.list)

all nodes in this namespace

=cut

sub list : Global {
    my ( $self, $c, $tag ) = @_;
    my $page = $c->stash->{page};
    $c->stash->{tags} = $c->model("DBIC::Tag")->most_used();
    $c->detach('/tag/list') if $tag;
    $c->stash->{template} = 'page/list.tt';
    $c->stash->{pages}    = [ $page->descendants ];

    # FIXME - real data here please
    $c->stash->{orphans} = [];
    $c->stash->{backlinks} =
      [ $c->model("DBIC::Link")->search( to_page => $page->id ) ];
    $c->stash->{wanted} = [
        $c->model("DBIC::WantedPage")->search(
            { from_page => [ $page->id, map { $_->id } $page->descendants ] }
        )
    ];
}

=head2 recent (.recent)

recently changed nodes in this namespace.

=cut

sub recent : Global {
    my ( $self, $c, $tag ) = @_;
    $c->detach( '/tag/recent', [$tag] ) if $tag;
    $c->stash->{tags} = $c->model("DBIC::Tag")->most_used;
    my $page = $c->stash->{page};
    $c->stash->{template} = 'page/recent.tt';
    $c->stash->{pages}    = [ $page->descendants_by_date ];

    # FIXME - needs to be populated even without tags
}

=head2 feeds (.feeds)

overview of available feeds for this node.

=cut

sub feeds : Global {
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'feeds.tt';
}

=head2 rss (.rss)

RSS feed with headlines of recent nodes in this namespace.

=cut

sub rss : Global {
    my ( $self, $c ) = @_;
    $c->forward('recent');
    $c->stash->{template} = 'page/rss.tt';
    $c->res->content_type('application/rss+xml');
}

=head2 atom (.atom)

Full content ATOM feed of recent nodes in this namespace.


=cut

sub atom : Global {
    my ( $self, $c ) = @_;
    $c->forward('recent');
    $c->res->content_type('application/atom+xml');
    $c->stash->{template} = 'page/atom.tt';
}

=head2 rss_full (.rss_full)

Full content RSS feed of recent nodes in this namespace.

=cut

sub rss_full : Global {
    my ( $self, $c ) = @_;
    $c->forward('recent');
    $c->res->content_type('application/rss+xml');
    $c->stash->{template} = 'page/rss_full.tt';
}

=head2  export (.export)

Page showing available export options.

=cut

sub export : Global {
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'export.tt';
}

=head2 suggest (.suggest)

Page not found page, suggesting alternatives, and allowing you to create the page.

=cut

sub suggest : Global {
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'page/suggest.tt';
    $c->res->status(404);
}

=head2 search_inline (.search/inline)

embedded search results in another page (for use with suggest).

=cut

sub search_inline : Path('/search/inline') {
    my ( $self, $c ) = @_;
    $c->forward('search');
    $c->stash->{template} = 'page/search_inline.tt';
}

=head2 info (.info)

Display meta information about the current page.

=cut

sub info : Global {
    my ( $self, $c ) = @_;
    $c->stash->{body_length} = length( $c->stash->{page}->content->body );
    $c->stash->{template}    = 'page/info.tt';
}

=head2 do_sitemap (.do_sitemap)

Create a sitemap.gz

=cut

sub do_sitemap : Global {
    my ( $self, $c ) = @_;
    return $c->forward('page_not_found')
      if !$c->user_exists;

    my $page  = $c->stash->{page};
    my @pages = $page->descendants_by_date;
    my $sitemap_file =
      Path::Class::Dir->new( $c->config->{sitemap_loc} )->file('sitemap.gz');
    my $map = WWW::Google::SiteMap->new(
        file   => "$sitemap_file",
        pretty => 1,
    );
    my $loc;
    my $month = 0;
    my $year  = 0;

    foreach my $entry (@pages) {
        if ( !$entry->content->noindex ) {
            if ( $entry->has_child && $entry->path ne '/' ) {
                $loc = $c->uri_for( $entry->path . '/' );
            }
            else {
                $loc = $c->uri_for( $entry->path );
            }
            $map->add( loc => $loc->as_string );
        }
        if ( $entry->content->release_date->year != 1970 ) {
            if (   $entry->content->release_date->month != $month
                || $entry->content->release_date->year != $year )
            {
                $month = $entry->content->release_date->month;
                $year  = $entry->content->release_date->year;
                my $date =
                  DateTime->now( time_zone => 'Europe/Paris', locale => 'fr' );
                if (   $entry->content->release_date->month == $date->month
                    && $entry->content->release_date->year == $date->year )
                {
                    $loc = $c->uri_for('/news/');
                    $map->add( loc => $loc->as_string );
                }
                else {
                    my $test = DateTime->new(
                        year      => $year,
                        month     => $month,
                        day       => 1,
                        time_zone => 'Europe/Paris',
                        locale    => 'fr'
                    );
                    $loc =
                      $c->uri_for( '/news/'
                          . $c->clean_string( $test->month_name ) . '-'
                          . $year );
                    $map->add( loc => $loc->as_string );
                }
            }
        }
    }

    $map->write;

    if ( $c->config->{gsm_ping} == 1 ) {
        use WWW::Google::SiteMap::Ping;
        my $sitemap_url = $c->uri_for('/sitemap.gz');
        my $ping        = WWW::Google::SiteMap::Ping->new( "$sitemap_url" );
        $ping->submit;
        if ( $ping->success ) {
            $c->res->body('sitemap generated and google ping succeeded');
            $c->detach();
        }
        else {
            $c->res->body('sitemap generated and google ping failed');
            $c->detach();
        }
    }
    $c->res->body(
"google sitemap generated, set config var 'gsm_ping' to equal 1 to enable automatic ping of google on generation"
    );
    $c->detach();

}

=head1 AUTHOR

Marcus Ramberg <mramberg@cpan.org>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as perl itself.

=cut

1;
