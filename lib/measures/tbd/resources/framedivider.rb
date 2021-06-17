require "openstudio"

##
# Calculate triangle area.
#
# @param [Array] pts Point3D array (3x)
#
# @return [Float] triangle area (m2)
# @return [Array] subsurface rough opening sorted Topolys 3D points
def areaHeron(pts)
  raise "Invalid pts (areaHeron)" unless pts
  raise "#{pts.class}? expected Array (areaHeron)" unless pts.is_a?(Array)
  raise "3x points please - got #{pts.size} (areaHeron)" unless pts.size == 3

  cl = Topolys::Point3D
  pts.each do |pt|
    raise "Topolys 3D points = got #{pt.class}" unless pt.class == cl
  end

  e = []
  e << { v0: pts[0], v1: pts[1], mag: (pts[1] - pts[0]).magnitude }
  e << { v0: pts[1], v1: pts[2], mag: (pts[2] - pts[1]).magnitude }
  e << { v0: pts[2], v1: pts[0], mag: (pts[0] - pts[2]).magnitude }

  raise "Unique triangle edges (areaHeron)" if matches?(e[0], e[1])
  raise "Unique triangle edges (areaHeron)" if matches?(e[1], e[2])
  raise "Unique triangle edges (areaHeron)" if matches?(e[2], e[0])

  e = e.sort_by{ |p| p[:mag] }

  area = 0
  # Kahan's stable implementation of Heron's formula for triangle area.
  # area = 1/4 sqrt( (a+(b+c)) (c-(a-b)) (c+(a-b)) (a+(b-c)) ) ... a > b > c
  a = e[0][:mag]
  b = e[1][:mag]
  c = e[2][:mag]
  return 0.25 * Math.sqrt( (a+(b+c)) * (c-(a-b)) * (c+(a-b)) * (a+(b-c)) )
end

##
# Calculate subsurface rough opening area & vertices.
#
# @param [OpenStudio::Model::Model] model An OS model
# @param [String] id SubSurface identifier
# @param [] id SubSurface identifier
#
# @return [Float] subsurface rough opening area (m2)
# @return [Array] subsurface rough opening sorted Topolys 3D points
def opening(model, id, t)
  raise "Invalid model (roughOpening)" unless model
  raise "Invalid ID (roughOpening)" unless id

  cl = OpenStudio::Model::Model
  raise "#{model.class}? expected #{cl} (roughOpening)" unless model.is_a?(cl)

  s = model.getSubSurfaceByName(id)
  raise "#{id} SubSurface missmatch!" if s.empty?
  s = s.get

  raise "Invalid parent surface (roughOpening)" if s.surface.empty?
  parent = model.getSurfaceByName(s.surface.get.nameString)
  raise "#{id} missing parent surface (roughOpening)!" if parent.empty?
  parent = parent.get

  area = s.grossArea
  raise "#{id} gross area < 0 m2 (roughOpening)?" unless area > TOL

  n = s.vertices.size
  raise "#{id} vertex count, 3 or 4 (roughOpening)!" unless n == 3 || n == 4

  # Transformed Topolys 3D points lists.
  points = (t * s.vertices).map{ |v| Topolys::Point3D.new(v.x, v.y, v.z) }
  dad = (t * parent.vertices).map{ |v| Topolys::Point3D.new(v.x, v.y, v.z) }

  # This creates an OpenStudio clone, flat on its face.
  os_dad = OpenStudio::Point3dVector.new
  dad.each do |v| os_dad << OpenStudio::Point3d.new(v.x, v.y, v.z); end
  ft = OpenStudio::Transformation::alignFace(os_dad).inverse
  flat_dad = (ft * os_dad).reverse

  # Should verify convexity of vertex wire/face ...
  #
  #       A
  #      / \
  #     /   \
  #    /     \
  #   / C --- D    <<< allowed as OpenStudio/E+ subsurface?
  #  / /
  #  B
  #
  # Should convert (annoying) 4-point subsurface into triangle ...
  #        A
  #       / \
  #      /   \
  #     /     \
  #    B - C - D   <<< allowed as OpenStudio/E+ subsurface?
  #
  return area, points if s.windowPropertyFrameAndDivider.empty?
  width = s.windowPropertyFrameAndDivider.get.frameWidth
  return area, points if width < TOL

  four = true if s.vertices.size == 4
  pts = {}

  pts[:A] = {}
  pts[:B] = {}
  pts[:C] = {}
  pts[:D] = {} if four

  pts[:A][:pt] = points[0]
  pts[:B][:pt] = points[1]
  pts[:C][:pt] = points[2]
  pts[:D][:pt] = points[3] if four

  # Generate vector pairs, from next point & from previous point.
  #
  #
  #
  #
  #
  #
  #             A <---------- B
  #              ^
  #               \
  #                \
  #                 C (or D)
  #
  pts[:A][:from_next] = pts[:A][:pt] - pts[:B][:pt]
  pts[:A][:from_prev] = pts[:A][:pt] - pts[:C][:pt] unless four
  pts[:A][:from_prev] = pts[:A][:pt] - pts[:D][:pt] if four

  pts[:B][:from_next] = pts[:B][:pt] - pts[:C][:pt]
  pts[:B][:from_prev] = pts[:B][:pt] - pts[:A][:pt]

  pts[:C][:from_next] = pts[:C][:pt] - pts[:A][:pt] unless four
  pts[:C][:from_next] = pts[:C][:pt] - pts[:D][:pt] if four
  pts[:C][:from_prev] = pts[:C][:pt] - pts[:B][:pt]

  pts[:D][:from_next] = pts[:D][:pt] - pts[:A][:pt] if four
  pts[:D][:from_prev] = pts[:D][:pt] - pts[:C][:pt] if four

  # Generate 3D plane from vectors.
  #
  #
  #             |  <<< 3D plane ... from point A, with normal B>A
  #             |
  #             |
  #             |
  # <---------- A <---------- B
  #             |\
  #             | \
  #             |  \
  #             |   C (or D)
  #
  pts[:A][:pl_from_next] = Topolys::Plane3D.new(pts[:A][:pt], pts[:A][:from_next])
  pts[:A][:pl_from_prev] = Topolys::Plane3D.new(pts[:A][:pt], pts[:A][:from_prev])

  pts[:B][:pl_from_next] = Topolys::Plane3D.new(pts[:B][:pt], pts[:B][:from_next])
  pts[:B][:pl_from_prev] = Topolys::Plane3D.new(pts[:B][:pt], pts[:B][:from_prev])

  pts[:C][:pl_from_next] = Topolys::Plane3D.new(pts[:C][:pt], pts[:C][:from_next])
  pts[:C][:pl_from_prev] = Topolys::Plane3D.new(pts[:C][:pt], pts[:C][:from_prev])

  pts[:D][:pl_from_next] = Topolys::Plane3D.new(pts[:D][:pt], pts[:D][:from_next]) if four
  pts[:D][:pl_from_prev] = Topolys::Plane3D.new(pts[:D][:pt], pts[:D][:from_prev]) if four

  # Project an extended point (pC) unto 3D plane.
  #
  #             pC   <<< projected unto extended B>A 3D plane
  #        eC   |
  #          \  |
  #           \ |
  #            \|
  # <---------- A <---------- B
  #             |\
  #             | \
  #             |  \
  #             |   C (or D)
  #
  pts[:A][:prev_unto_next_pl] = pts[:A][:pl_from_next].project(pts[:A][:pt] + pts[:A][:from_prev])
  pts[:A][:next_unto_prev_pl] = pts[:A][:pl_from_prev].project(pts[:A][:pt] + pts[:A][:from_next])

  pts[:B][:prev_unto_next_pl] = pts[:B][:pl_from_next].project(pts[:B][:pt] + pts[:B][:from_prev])
  pts[:B][:next_unto_prev_pl] = pts[:B][:pl_from_prev].project(pts[:B][:pt] + pts[:B][:from_next])

  pts[:C][:prev_unto_next_pl] = pts[:C][:pl_from_next].project(pts[:C][:pt] + pts[:C][:from_prev])
  pts[:C][:next_unto_prev_pl] = pts[:C][:pl_from_prev].project(pts[:C][:pt] + pts[:C][:from_next])

  pts[:D][:prev_unto_next_pl] = pts[:D][:pl_from_next].project(pts[:D][:pt] + pts[:D][:from_prev]) if four
  pts[:D][:next_unto_prev_pl] = pts[:D][:pl_from_prev].project(pts[:D][:pt] + pts[:D][:from_next]) if four

  # Generate vector from point (e.g. A) to projected extended point (pC).
  #
  #             pC
  #        eC   ^
  #          \  |
  #           \ |
  #            \|
  # <---------- A <---------- B
  #             |\
  #             | \
  #             |  \
  #             |   C (or D)
  #
  pts[:A][:n_prev_unto_next_pl] = pts[:A][:prev_unto_next_pl] - pts[:A][:pt]
  pts[:A][:n_next_unto_prev_pl] = pts[:A][:next_unto_prev_pl] - pts[:A][:pt]

  pts[:B][:n_prev_unto_next_pl] = pts[:B][:prev_unto_next_pl] - pts[:B][:pt]
  pts[:B][:n_next_unto_prev_pl] = pts[:B][:next_unto_prev_pl] - pts[:B][:pt]

  pts[:C][:n_prev_unto_next_pl] = pts[:C][:prev_unto_next_pl] - pts[:C][:pt]
  pts[:C][:n_next_unto_prev_pl] = pts[:C][:next_unto_prev_pl] - pts[:C][:pt]

  pts[:D][:n_prev_unto_next_pl] = pts[:D][:prev_unto_next_pl] - pts[:D][:pt] if four
  pts[:D][:n_next_unto_prev_pl] = pts[:D][:next_unto_prev_pl] - pts[:D][:pt] if four

  # Fetch angle between both extended vectors (A>pC & A>pB), then normalize (Cn).
  #
  #             pC
  #        eC   ^
  #          \  |
  #           \ Cn
  #            \|
  # <---------- A <---------- B
  #             |\
  #             | \
  #             |  \
  #             |   C (or D)
  #
  pts[:A][:angle] = pts[:A][:n_prev_unto_next_pl].angle(pts[:A][:n_next_unto_prev_pl])
  pts[:B][:angle] = pts[:B][:n_prev_unto_next_pl].angle(pts[:B][:n_next_unto_prev_pl])
  pts[:C][:angle] = pts[:C][:n_prev_unto_next_pl].angle(pts[:C][:n_next_unto_prev_pl])
  pts[:D][:angle] = pts[:D][:n_prev_unto_next_pl].angle(pts[:D][:n_next_unto_prev_pl]) if four

  # Generate new 3D points A', B', C' (and D') ... zigzag.
  #
  #
  #
  #
  #     A' ---------------------- B'
  #      \
  #       \      A <---------- B
  #        \      \
  #         \      \
  #          \      \
  #           C'      C
  pts[:A][:from_next].normalize!
  pts[:A][:n_prev_unto_next_pl].normalize!
  pts[:A][:p] = pts[:A][:pt] + (pts[:A][:n_prev_unto_next_pl] * width) + (pts[:A][:from_next] * width * Math.tan(pts[:A][:angle]/2))

  pts[:B][:from_next].normalize!
  pts[:B][:n_prev_unto_next_pl].normalize!
  pts[:B][:p] = pts[:B][:pt] + (pts[:B][:n_prev_unto_next_pl] * width) + (pts[:B][:from_next] * width * Math.tan(pts[:B][:angle]/2))

  pts[:C][:from_next].normalize!
  pts[:C][:n_prev_unto_next_pl].normalize!
  pts[:C][:p] = pts[:C][:pt] + (pts[:C][:n_prev_unto_next_pl] * width) + (pts[:C][:from_next] * width * Math.tan(pts[:C][:angle]/2))

  pts[:D][:from_next].normalize! if four
  pts[:D][:n_prev_unto_next_pl].normalize! if four
  pts[:D][:p] = pts[:D][:pt] + (pts[:D][:n_prev_unto_next_pl] * width) + (pts[:D][:from_next] * width * Math.tan(pts[:D][:angle]/2)) if four

  # Convert Topolys 3D points into OpenStudio 3D points for fitting test.
  vec = OpenStudio::Point3dVector.new
  vec << OpenStudio::Point3d.new(pts[:A][:p].x, pts[:A][:p].y, pts[:A][:p].z)
  vec << OpenStudio::Point3d.new(pts[:B][:p].x, pts[:B][:p].y, pts[:B][:p].z)
  vec << OpenStudio::Point3d.new(pts[:C][:p].x, pts[:C][:p].y, pts[:C][:p].z)
  vec << OpenStudio::Point3d.new(pts[:D][:p].x, pts[:D][:p].y, pts[:D][:p].z) if four

  flat_points = ft * vec
  flat_points.each do |flat_point|
    return area, points unless OpenStudio::pointInPolygon(flat_point, flat_dad, TOL)
  end
  # At some point, also check for conflicts with other subsurfaces ...

  tr1 = []
  tr1 << pts[:A][:p]
  tr1 << pts[:B][:p]
  tr1 << pts[:C][:p]
  area1 = areaHeron(tr1)
  area2 = 0
  if four
    tr2 = []
    tr2 << pts[:A][:p]
    tr2 << pts[:C][:p]
    tr2 << pts[:D][:p]
    area2 = areaHeron(tr2)
  end
  area = area1 + area2

  points3D = []
  points3D << pts[:A][:p]
  points3D << pts[:B][:p]
  points3D << pts[:C][:p]
  points3D << pts[:D][:p] if four

  return area, points3D
end
