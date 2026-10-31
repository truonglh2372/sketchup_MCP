# The only file that talks to the SketchUp API. Runs on the main thread (called
# from Server#tick inside the dialog callback). Ruby 2.7-safe for SketchUp 2023.
require "tmpdir"
require_relative "evaluator"

module SketchupMcpBridge
  class Handlers
    MM_PER_INCH = 25.4
    MM2_PER_IN2 = 645.16

    def initialize
      @evaluator = Evaluator.new(wrap: method(:with_operation))
    end

    def ping(_params)
      model = Sketchup.active_model
      {
        "sketchup_version" => Sketchup.version,
        "ruby_version" => RUBY_VERSION,
        "model_title" => model.title,
        "model_path" => model.path,
        "length_unit" => length_unit(model),
        "selection_count" => model.selection.size,
        "active_path" => (model.active_path || []).map { |e| label(e) }
      }
    end

    def eval_ruby(params)
      @evaluator.run(params["code"].to_s, operation: params["operation_name"])
    end

    def get_selection(_params)
      sel = Sketchup.active_model.selection
      { "count" => sel.size, "entities" => sel.to_a.first(500).map { |e| summary(e) } }
    end

    def list_entities(params)
      limit = (params["limit"] || 200).to_i
      ents = Sketchup.active_model.active_entities.to_a
      { "total" => ents.size, "entities" => ents.first(limit).map { |e| summary(e) } }
    end

    def dump_entity(params)
      model = Sketchup.active_model
      ent = if params["entity_id"]
        model.find_entity_by_id(params["entity_id"].to_i)
      else
        model.selection.first
      end
      raise ArgumentError, "Entity not found (select one or pass entity_id)" unless ent
      return summary(ent) unless instance?(ent)

      max_faces = (params["max_faces"] || 2000).to_i
      ents = ent.definition.entities
      faces = ents.grep(Sketchup::Face)
      summary(ent).merge(
        "transform" => ent.transformation.to_a.each_slice(4).to_a,
        "coordinates" => "definition-local, mm",
        "faces_truncated" => faces.size > max_faces,
        "faces" => faces.first(max_faces).map { |f| face_data(f) },
        "edges" => ents.grep(Sketchup::Edge).first(max_faces * 4).map { |e| edge_data(e) },
        "instances" => ents.select { |e| instance?(e) }.map { |e| summary(e) }
      )
    end

    def screenshot(params)
      view = Sketchup.active_model.active_view
      width = (params["width"] || 1280).to_i
      height = (params["height"] || (width * view.vpheight / view.vpwidth.to_f).round).to_i
      path = File.join(Dir.tmpdir, "sketchup_mcp_#{Process.pid}_#{Time.now.to_f.to_s.tr('.', '')}.png")
      ok = view.write_image(filename: path, width: width, height: height, antialias: true, transparent: false)
      raise "write_image failed" unless ok && File.exist?(path)

      { "path" => path, "width" => width, "height" => height }
    end

    def undo(_params)
      Sketchup.undo
      { "undone" => true }
    end

    private

    def with_operation(name)
      model = Sketchup.active_model
      model.start_operation(name, true)
      begin
        result = yield
        model.commit_operation
        result
      rescue Exception # rubocop:disable Lint/RescueException — SyntaxError too
        model.abort_operation
        raise
      end
    end

    def instance?(e)
      e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
    end

    def label(e)
      instance?(e) ? "#{e.class.name.split('::').last}(#{e.name.empty? ? e.definition.name : e.name})" : e.class.name
    end

    def summary(e)
      h = { "class" => e.class.name, "entityID" => e.entityID }
      h["persistent_id"] = e.persistent_id if e.respond_to?(:persistent_id)
      h["tag"] = e.layer.name if e.respond_to?(:layer) && e.layer
      if instance?(e)
        h["name"] = e.name
        h["definition"] = e.definition.name
        ents = e.definition.entities
        h["faces"] = ents.grep(Sketchup::Face).size
        h["edges"] = ents.grep(Sketchup::Edge).size
        h["material"] = e.material.display_name if e.material
      end
      h["bounds_mm"] = bounds_mm(e.bounds) if e.respond_to?(:bounds)
      h
    end

    def bounds_mm(bb)
      { "width" => mm(bb.width), "depth" => mm(bb.height), "height" => mm(bb.depth),
        "min" => pt(bb.min), "max" => pt(bb.max) }
    end

    def face_data(f)
      n = f.normal
      {
        "entityID" => f.entityID,
        "area_mm2" => (f.area * MM2_PER_IN2).round(3),
        "normal" => [n.x, n.y, n.z].map { |v| v.round(6) },
        "outer_mm" => f.outer_loop.vertices.map { |v| pt(v.position) },
        "inner_loops" => f.loops.size - 1,
        "material" => f.material && f.material.display_name
      }
    end

    def edge_data(e)
      { "entityID" => e.entityID, "start_mm" => pt(e.start.position), "end_mm" => pt(e.end.position),
        "faces" => e.faces.size, "soft" => e.soft?, "smooth" => e.smooth? }
    end

    def pt(p)
      [mm(p.x), mm(p.y), mm(p.z)]
    end

    def mm(v)
      (v.to_f * MM_PER_INCH).round(3)
    end

    def length_unit(model)
      code = model.options["UnitsOptions"]["LengthUnit"]
      { 0 => "inch", 1 => "feet", 2 => "mm", 3 => "cm", 4 => "m" }.fetch(code, code.to_s)
    rescue StandardError
      nil
    end
  end
end
