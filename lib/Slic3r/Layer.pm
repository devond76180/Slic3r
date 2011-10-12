package Slic3r::Layer;
use Moo;

use Math::Clipper ':all';
use Math::ConvexHull qw(convex_hull);
use Slic3r::Geometry qw(polygon_lines points_coincide angle3points polyline_lines nearest_point
    line_length);
use Slic3r::Geometry::Clipper qw(union_ex);
use XXX;

use constant PI => 4 * atan2(1, 1);
use constant A => 0;
use constant B => 1;

# a sequential number of layer, starting at 0
has 'id' => (
    is          => 'ro',
    #isa         => 'Int',
    required    => 1,
);

# collection of spare segments generated by slicing the original geometry;
# these need to be merged in continuos (closed) polylines
has 'lines' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Line]',
    default => sub { [] },
);

# collection of surfaces generated by slicing the original geometry
has 'surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface]',
    default => sub { [] },
);

# collection of surfaces representing bridges
has 'bridges' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface::Bridge]',
    default => sub { [] },
);

# collection of surfaces to make perimeters for
has 'perimeter_surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface]',
    default => sub { [] },
);

# ordered collection of extrusion paths to build all perimeters
has 'perimeters' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionLoop]',
    default => sub { [] },
);

# ordered collection of extrusion paths to build skirt loops
has 'skirts' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionLoop]',
    default => sub { [] },
);

# collection of surfaces generated by offsetting the innermost perimeter(s)
# they represent boundaries of areas to fill
has 'fill_surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface::Collection]',
    default => sub { [] },
);

# ordered collection of extrusion paths to fill surfaces
has 'fills' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionPath]',
    default => sub { [] },
);

sub z {
    my $self = shift;
    return ($self->id * $Slic3r::layer_height + $Slic3r::layer_height/2) / $Slic3r::resolution;
}

sub add_surface {
    my $self = shift;
    my (@vertices) = @_;
    
    # convert arrayref points to Point objects
    @vertices = map Slic3r::Point->new($_), @vertices;
    
    my $surface = Slic3r::Surface->new(
        contour => Slic3r::Polyline::Closed->new(points => \@vertices),
    );
    push @{ $self->surfaces }, $surface;
    
    # make sure our contour has its points in counter-clockwise order
    $surface->contour->make_counter_clockwise;
    
    return $surface;
}

sub add_line {
    my $self = shift;
    my ($line) = @_;
    
    return if $line->a->coincides_with($line->b);
    
    push @{ $self->lines }, $line;
    return $line;
}

sub remove_line {
    my $self = shift;
    my ($line) = @_;
    @{ $self->lines } = grep $_ ne $line, @{ $self->lines };
}

sub remove_surface {
    my $self = shift;
    my ($surface) = @_;
    @{ $self->surfaces } = grep $_ ne $surface, @{ $self->surfaces };
}

# build polylines from lines
sub make_surfaces {
    my $self = shift;
    
    # this algorithm can be further simplified:
    # first remove all facetedges that are not connected to any other edge
    # or that are connected to more than one edge: those are the edges
    # tangent to our plane, that we don't care about;
    # then we would have all points connecting two and only two lines,
    # so a simple head-to-tail algorithm would work
    
    my @lines = ();
    push @lines, @{$self->lines};
    #@lines = grep line_length($_) > xx, @lines;
    
    #use Slic3r::SVG;
    #Slic3r::SVG::output(undef, "lines.svg",
    #    lines       => [ map $_->p, grep !$_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
    #    red_lines   => [ map $_->p, grep  $_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
    #);
    
    my $get_point_id = sub { sprintf "%.0f,%.0f", @{$_[0]} };
    
    my (%pointmap, @pointmap_keys) = ();
    foreach my $line (@lines) {
        my $point_id = $get_point_id->($line->[A]);
        if (!exists $pointmap{$point_id}) {
            $pointmap{$point_id} = [];
            push @pointmap_keys, $line->[A];
        }
        push @{ $pointmap{$point_id} }, $line;
    }
    
    my $n = 0;
    my @polylines = ();
    while (my $first_line = shift @lines) {
        my @points = @$first_line;
        my %seen_points = map { $get_point_id->($points[$_]) => $_ } 0..1;
        
        CYCLE: while (1) {
            my $next_lines = $pointmap{ $get_point_id->($points[-1]) };
            
            # shouldn't we find the point, let's try with a slower algorithm
            # as approximation may make the coordinates differ
            if (!$next_lines) {
                my $nearest_point = nearest_point($points[-1], \@pointmap_keys);
                #printf "  we have a nearest point: %f,%f (%s)\n", @$nearest_point, $get_point_id->($nearest_point);
                
                if ($nearest_point) {
                    local $Slic3r::Geometry::epsilon = 1000000;
                    $next_lines = $pointmap{$get_point_id->($nearest_point)}
                        if points_coincide($points[-1], $nearest_point);
                }
            }
            
            #Slic3r::SVG::output(undef, "lines.svg",
            #    lines       => [ map $_->p, grep !$_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
            #    red_lines   => [ map $_->p, grep  $_->isa('Slic3r::Line::FacetEdge'), @{$self->lines} ],
            #    points      => [ $points[-1] ],
            #    no_arrows => 1,
            #) if !$next_lines;
            
            $next_lines
                or die sprintf("No lines start at point %s. This shouldn't happen", $get_point_id->($points[-1]));
            last CYCLE if !@$next_lines;
            
            my @ordered_next_lines = sort 
                { angle3points($points[-1], $points[-2], $next_lines->[$a][B]) <=> angle3points($points[-1], $points[-2], $next_lines->[$b][B]) } 
                0..$#$next_lines;
            
            #if (@$next_lines > 1) {
            #    Slic3r::SVG::output(undef, "next_line.svg",
            #        lines        => $next_lines,
            #        red_lines    => [ polyline_lines([@points]) ],
            #        green_lines  => [ $next_lines->[ $ordered_next_lines[0] ] ],
            #    );
            #}
            
            my ($next_line) = splice @$next_lines, $ordered_next_lines[0], 1;
            
            
            push @points, $next_line->[B];
            
            my $point_id = $get_point_id->($points[-1]);
            if ($seen_points{$point_id}) {
                splice @points, 0, $seen_points{$point_id};
                last CYCLE;
            }
            
            $seen_points{$point_id} = $#points;
        }
        
        if (@points < 4 || !points_coincide($points[0], $points[-1])) {
            next;
        }
        
        pop @points;
        Slic3r::debugf "Discovered polyline of %d points\n", scalar(@points);
        push @polylines, [@points];
    }
    
    {
        my $expolygons = union_ex([ @polylines ]);
        Slic3r::debugf "  %d surface(s) detected from %d polylines\n",
            scalar(@$expolygons), scalar(@polylines);
        
        push @{$self->surfaces}, map Slic3r::Surface->cast_from_expolygon($_, surface_type => 'internal'), @$expolygons;
    }
    
    #use Slic3r::SVG;
    #Slic3r::SVG::output(undef, "surfaces.svg",
    #    polygons        => [ map $_->contour->p, @{$self->surfaces} ],
    #    red_polygons    => [ map $_->p, map @{$_->holes}, @{$self->surfaces} ],
    #);
}

sub remove_small_surfaces {
    my $self = shift;
    my @good_surfaces = ();
    
    my $surface_count = scalar @{$self->surfaces};
    foreach my $surface (@{$self->surfaces}) {
        next if !$surface->contour->is_printable;
        @{$surface->holes} = grep $_->is_printable, @{$surface->holes};
        push @good_surfaces, $surface;
    }
    
    @{$self->surfaces} = @good_surfaces;
    Slic3r::debugf "removed %d small surfaces at layer %d\n",
        ($surface_count - @good_surfaces), $self->id 
        if @good_surfaces != $surface_count;
}

sub remove_small_perimeters {
    my $self = shift;
    my @good_perimeters = grep $_->is_printable, @{$self->perimeters};
    Slic3r::debugf "removed %d unprintable perimeters at layer %d\n",
        (@{$self->perimeters} - @good_perimeters), $self->id
        if @good_perimeters != @{$self->perimeters};
    
    @{$self->perimeters} = @good_perimeters;
}

# make bridges printable
sub process_bridges {
    my $self = shift;
    return if $self->id == 0;
    
    # a bottom surface on a layer > 0 is either a bridge or a overhang 
    # or a combination of both
    
    my @bottom_surfaces     = grep $_->surface_type eq 'bottom',   @{$self->surfaces} or return;
    my @supporting_surfaces = grep $_->surface_type =~ /internal/, @{$self->surfaces};
    
    SURFACE: foreach my $surface (@bottom_surfaces) {
        # since we can't print concave bridges, we transform the surface
        # in a convex polygon; this will print thin membranes eventually
        my $surface_p = convex_hull($surface->contour->p);
        
            #use Slic3r::SVG;
            #Slic3r::SVG::output(undef, "bridge.svg",
            #    green_polygons  => [ map $_->p, @supporting_surfaces ],
            #    red_polygons    => [ $surface_p ],
            #);
        
        # find all supported edges (as polylines, thus keeping notion of 
        # consecutive supported edges)
        my @supported_polylines = ();
        {
            my @current_polyline = ();
            EDGE: foreach my $edge (Slic3r::Geometry::polygon_lines($surface_p)) {
                for my $supporting_surface (@supporting_surfaces) {
                    local $Slic3r::Geometry::epsilon = 1E+7;
                    if (Slic3r::Geometry::polygon_has_subsegment($supporting_surface->contour->p, $edge)) {
                        push @current_polyline, $edge;
                        next EDGE;
                    }
                }
                if (@current_polyline) {
                    push @supported_polylines, [@current_polyline];
                    @current_polyline = ();
                }
            }
            push @supported_polylines, [@current_polyline] if @current_polyline;
        }
        
        # defensive programming, this shouldn't happen
        if (@supported_polylines == 0) {
            Slic3r::debugf "Found bridge/overhang with no supports on layer %d; ignoring\n", $self->id;
            next SURFACE;
        }
        
        if (@supported_polylines == 1) {
            Slic3r::debugf "Found bridge/overhang with only one support on layer %d; ignoring\n", $self->id;
            next SURFACE;
        }
        
        # now connect the first point to the last of each polyline
        @supported_polylines = map [ $_->[0]->[0], $_->[-1]->[-1] ], @supported_polylines;
        # @supported_polylines becomes actually an array of lines
        
        # if we got more than two supports, get the longest two
        if (@supported_polylines > 2) {
            my %lengths = map { $_ => Slic3r::Geometry::line_length($_) } @supported_polylines;
            @supported_polylines = sort { $lengths{"$a"} <=> $lengths{"$b"} } @supported_polylines;
            @supported_polylines = @supported_polylines[-2,-1];
        }
        
        # connect the midpoints, that will give the the optimal infill direction
        my @midpoints = map Slic3r::Geometry::midpoint($_), @supported_polylines;
        my $bridge_angle = -Slic3r::Geometry::rad2deg(Slic3r::Geometry::line_atan(\@midpoints) + PI/2);
        Slic3r::debugf "Optimal infill angle of bridge on layer %d is %d degrees\n", $self->id, $bridge_angle;
        
        # detect which neighbor surfaces are now supporting our bridge
        my @supporting_neighbor_surfaces = ();
        foreach my $supporting_surface (@supporting_surfaces) {
            local $Slic3r::Geometry::epsilon = 1E+7;
            push @supporting_neighbor_surfaces, $supporting_surface 
                if grep Slic3r::Geometry::polygon_has_vertex($supporting_surface->contour->p, $_), 
                    map $_->[0], @supported_polylines;
        }
        
        # defensive programming, this shouldn't happen
        if (@supporting_neighbor_surfaces == 0) {
            Slic3r::debugf "Couldn't find supporting surfaces on layer %d; ignoring\n", $self->id;
            next SURFACE;
        }
        
        # now, extend our bridge by taking a portion of supporting surfaces
        {
            # offset the bridge by the specified amount of mm
            my $bridge_offset = ${ offset([$surface_p], $Slic3r::bridge_overlap / $Slic3r::resolution, $Slic3r::resolution * 100, JT_MITER, 2) }[0];
            
            # calculate the new bridge
            my $clipper = Math::Clipper->new;
            $clipper->add_subject_polygon($surface_p);
            $clipper->add_subject_polygons([ map $_->p, @supporting_neighbor_surfaces ]);
            $clipper->add_clip_polygon($bridge_offset);
            my $intersection = $clipper->execute(CT_INTERSECTION, PFT_NONZERO, PFT_NONZERO);
            
            push @{$self->bridges}, map Slic3r::Surface::Bridge->cast_from_polygon($_,
                surface_type => 'bottom',
                bridge_angle => $bridge_angle,
            ), @$intersection;
        }
    }
}

# generates a set of surfaces that will be used to make perimeters
# thus, we need to merge internal surfaces and bridges
sub detect_perimeter_surfaces {
    my $self = shift;
    
    # little optimization: skip the Clipper UNION if we have no bridges
    if (!@{$self->bridges}) {
        push @{$self->perimeter_surfaces}, @{$self->surfaces};
    } else {
        my $clipper = Math::Clipper->new;
        $clipper->add_subject_polygons([ map $_->p, grep $_->surface_type =~ /internal/, @{$self->surfaces} ]);
        $clipper->add_clip_polygons([ map $_->p, @{$self->bridges} ]);
        my $union = $clipper->ex_execute(CT_UNION, PFT_NONZERO, PFT_NONZERO);
        
        push @{$self->perimeter_surfaces}, 
            map Slic3r::Surface->cast_from_expolygon($_, surface_type => 'internal'), 
            @$union;
        
        push @{$self->perimeter_surfaces}, 
            grep $_->surface_type !~ /internal/ && ($_->surface_type ne 'bottom' || $self->id == 0), 
            @{$self->surfaces};
    }
}

# splits fill_surfaces in internal and bridge surfaces
sub split_bridges_fills {
    my $self = shift;
    
    my $clipper = Math::Clipper->new;
    foreach my $surf_coll (@{$self->fill_surfaces}) {
        my @surfaces = @{$surf_coll->surfaces};
        @{$surf_coll->surfaces} = ();
        
        # intersect fill_surfaces with bridges to get actual bridges
        foreach my $bridge (@{$self->bridges}) {
            $clipper->clear;
            $clipper->add_subject_polygons([ map $_->p, @surfaces ]);
            $clipper->add_clip_polygon($bridge->contour->p);
            my $intersection = $clipper->ex_execute(CT_INTERSECTION, PFT_NONZERO, PFT_NONZERO);
            push @{$surf_coll->surfaces}, map Slic3r::Surface::Bridge->cast_from_expolygon($_,
                surface_type => 'bottom',
                bridge_angle => $bridge->bridge_angle,
            ), @$intersection;
        }
        
        # difference between fill_surfaces and bridges are the other surfaces
        foreach my $surface (@surfaces) {
            $clipper->clear;
            $clipper->add_subject_polygons([ $surface->p ]);
            $clipper->add_clip_polygons([ map $_->contour->p, @{$self->bridges} ]);
            my $difference = $clipper->ex_execute(CT_DIFFERENCE, PFT_NONZERO, PFT_NONZERO);
            push @{$surf_coll->surfaces}, map Slic3r::Surface->cast_from_expolygon($_,
                surface_type => $surface->surface_type), @$difference;
        }
    }
}

1;
