import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class BlenderAssist:ObservableObject {
    nonisolated static let moves = ["Slow pullback","Slow push in","Gentle orbit"]
    @Published var busy = false
    @Published var progress:Double = 0
    @Published var message = "A real 3D photo insert: packed image, paper border, tabletop, light and animated camera."
    @Published var candidateID:UUID?
    @Published var projectID:UUID?
    @Published var resultShotID:UUID?
    @Published var detail = false
    @Published var executable:String
    private var work:Task<Void,Never>?
    private var process:Process?
    private let directory:URL
    init(executable:String? = nil,directory:URL? = nil) {
        self.executable = executable ?? UserDefaults.standard.string(forKey:"blender.executable") ?? ["/Applications/Blender.app/Contents/MacOS/Blender",NSHomeDirectory()+"/Applications/Blender.app/Contents/MacOS/Blender"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) ?? ""
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Stillroom/Blender")
    }
    var available:Bool {FileManager.default.isExecutableFile(atPath:executable)}
    func choose() {
        let panel = NSOpenPanel();panel.message = "Choose your installed Blender.app. No download is needed.";panel.allowedContentTypes = [.applicationBundle];panel.canChooseDirectories = false
        panel.begin {response in
            guard response == .OK,let url = panel.url else {return}
            Task {@MainActor in
                let binary = url.appendingPathComponent("Contents/MacOS/Blender").path
                guard FileManager.default.isExecutableFile(atPath:binary) else {self.message = "Choose a Blender application with its executable inside the app bundle.";return}
                self.executable = binary;UserDefaults.standard.set(binary,forKey:"blender.executable");self.message = "Blender connected · renders locally on this Mac"
            }
        }
    }
    nonisolated static func frames(duration:Double,fps:Int) throws -> Int {
        guard duration.isFinite,duration >= 1,duration <= 60,[24,25,30,60].contains(fps) else {throw StudioError.message("Blender photo inserts support shots from 1 to 60 seconds.")}
        return max(1,Int((duration*Double(fps)).rounded()))
    }
    private func run(_ executable:String,_ arguments:[String],log:URL,frames:URL? = nil,count:Int = 0) async throws {
        FileManager.default.createFile(atPath:log.path,contents:Data())
        let output = try FileHandle(forWritingTo:log);defer {try? output.close()}
        let worker = Process();worker.executableURL = URL(fileURLWithPath:executable);worker.arguments = arguments
        worker.standardOutput = output;worker.standardError = output
        process = worker;defer {process = nil}
        try worker.run()
        do {
            while worker.isRunning {
                try Task.checkCancellation()
                if let frames,count > 0 {
                    let done = (try? FileManager.default.contentsOfDirectory(atPath:frames.path).filter {$0.hasSuffix(".png")}.count) ?? 0
                    progress = min(0.94,Double(done)/Double(count)*0.94)
                    message = "Blender · \(done) of \(count) frames rendered"
                }
                try await Task.sleep(nanoseconds:250_000_000)
            }
        } catch {
            if worker.isRunning {worker.terminate()}
            // Poll asynchronously so cancellation never blocks the main thread.
            while worker.isRunning {try? await Task.sleep(nanoseconds:100_000_000)}
            throw error
        }
        guard worker.terminationStatus == 0 else {
            let data = (try? Data(contentsOf:log)) ?? Data()
            throw StudioError.message("Blender insert could not finish. " + String(decoding:data.suffix(700),as:UTF8.self))
        }
    }
    func render(_ suggestion:EditSuggestion,store:StudioStore) {
        let lab = store.generation
        guard !busy,!lab.busy,!lab.referenceBusy,!store.assistant.busy,available else {message = "Connect Blender and let the current generation finish first.";return}
        guard suggestion.kind == .blender,let shot = store.project.shots.first(where:{$0.id.uuidString == suggestion.target}),let source = store.project.assets.first(where:{$0.id == shot.assetID}) else {return}
        do {var check = store.project;try suggestion.applying(to:&check)} catch {message = error.localizedDescription;return}
        let document = store.documentID,sourceURL = store.url(source),fps = store.project.fps
        let reference = store.project.assets.first {$0.id.uuidString == suggestion.source && $0.kind == .image} ?? source.referenceAssetID.flatMap {id in store.project.assets.first {$0.id == id && $0.kind == .image}}
        let referenceURL = reference.map {store.url($0)}
        let rootID = store.project.familyRoot(of:source),binary = executable,large = detail
        busy = true;lab.referenceBusy = true;progress = 0;candidateID = nil;projectID = nil;resultShotID = nil
        work = Task {
            do {
                if let queue = try? await lab.json("queue"),!(queue["queue_running"] as? [[Any]] ?? []).isEmpty {throw StudioError.message("Let the running local video render finish before rendering a Blender insert.")}
                let count = try Self.frames(duration:shot.duration,fps:fps)
                guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else {throw StudioError.message("FFmpeg is needed to encode the Blender frames into a movie.")}
                let folder = directory.appendingPathComponent(UUID().uuidString),frames = folder.appendingPathComponent("Frames")
                try FileManager.default.createDirectory(at:frames,withIntermediateDirectories:true)
                let image:Data
                if let referenceURL {image = try VideoColor.referencePNG(at:referenceURL)}
                else if source.kind == .image {image = try VideoColor.referencePNG(at:sourceURL)}
                else {
                    let generator = AVAssetImageGenerator(asset:AVURLAsset(url:sourceURL));generator.appliesPreferredTrackTransform = true;generator.maximumSize = CGSize(width:1920,height:1080)
                    image = try VideoColor.referencePNG(try await generator.image(at:CMTime(seconds:shot.sourceIn,preferredTimescale:600)).image)
                }
                let texture = folder.appendingPathComponent("Reference.png"),blend = folder.appendingPathComponent("Photo-insert.blend"),movie = folder.appendingPathComponent("Photo-insert.mp4")
                try image.write(to:texture,options:.atomic)
                let config:[String:Any] = ["image":texture.path,"blend":blend.path,"frames":frames.path,"count":count,"fps":fps,"width":large ? 1920 : 960,"height":large ? 1080 : 540,"move":suggestion.camera]
                let configURL = folder.appendingPathComponent("Scene.json"),script = folder.appendingPathComponent("Build-scene.py")
                try JSONSerialization.data(withJSONObject:config,options:.sortedKeys).write(to:configURL)
                try Self.script.write(to:script,atomically:true,encoding:.utf8)
                message = "Building the 3D photo, tabletop and camera…"
                try await run(binary,["--background","--factory-startup","--python-exit-code","1","--python",script.path,"--",configURL.path],log:folder.appendingPathComponent("Blender.log"),frames:frames,count:count)
                try Task.checkCancellation();message = "Encoding the Blender take with explicit color metadata…";progress = 0.96
                try await run(ffmpeg,["-v","error","-y","-framerate",String(fps),"-i",frames.appendingPathComponent("Frame-%05d.png").path,"-vf","scale=out_color_matrix=bt709","-c:v","libx264","-preset","fast","-crf","18","-pix_fmt","yuv420p","-color_primaries","bt709","-color_trc","iec61966-2-1","-colorspace","bt709","-movflags","+faststart",movie.path],log:folder.appendingPathComponent("Encode.log"))
                try Task.checkCancellation()
                guard store.documentID == document else {throw StudioError.message("The project changed. The Blender render remains saved locally; it was not added to the new project.")}
                var media = try await MediaEngine.inspect(movie)
                media.name = "Blender · " + shot.name;media.origin = "Blender photo insert";media.parentAssetID = rootID;media.referenceAssetID = reference?.id
                media.prompt = "\(suggestion.camera). Photo card on a tabletop. " + suggestion.reason
                media.notes = "Rendered from a packed Blender scene. The source is a flat photograph on 3D geometry, not a reconstruction of the scene. Review before use."
                let scene = MediaAsset(name:"Blender scene · " + shot.name,path:blend.path,kind:.blender,origin:"Stillroom Blender assist",notes:"Packed reference texture; paper card, tabletop, area light and animated 50 mm camera.")
                let anchor = store.assistant.base
                store.change({$0.assets += [media,scene]},rebuild:false);store.refreshMedia()
                if let anchor,anchor == store.undoStack.last {store.assistant.base = store.project}
                candidateID = media.id;projectID = scene.id;resultShotID = shot.id;progress = 1
                message = "Blender take ready · review it, then choose whether to fit it to this shot"
            } catch {message = Task.isCancelled ? "Blender render cancelled. The edit is unchanged." : error.localizedDescription}
            busy = false;lab.referenceBusy = false
        }
    }
    func cancel() {work?.cancel()}
    // The model chooses only a supported move. It never supplies executable code.
    static let script = #"""
import bpy, json, math, sys, os
from mathutils import Vector, Matrix
cfg = json.load(open(sys.argv[sys.argv.index('--')+1], encoding='utf-8'))
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 8
scene.cycles.use_denoising = True
scene.cycles.device = 'CPU'
scene.render.resolution_x = cfg['width']
scene.render.resolution_y = cfg['height']
scene.render.resolution_percentage = 100
scene.render.fps = cfg['fps']
scene.frame_start = 1
scene.frame_end = cfg['count']
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGB'
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.view_settings.exposure = 0
scene.view_settings.gamma = 1
scene.world.color = (0.14,0.14,0.14)
image = bpy.data.images.load(cfg['image'])
image.colorspace_settings.name = 'sRGB'
w = 4.0
h = w * image.size[1] / image.size[0]
def surface(name, width, height, z, color):
    bpy.ops.mesh.primitive_plane_add(size=2, location=(0,0,z))
    obj = bpy.context.object
    obj.name = name
    obj.scale = (width/2,height/2,1)
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color,1)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = (*color,1)
    bsdf.inputs['Roughness'].default_value = 0.8
    obj.data.materials.append(mat)
    return obj, mat
table,_ = surface('Matte tabletop',200,200,-0.03,(0.10,0.085,0.065))
paper,_ = surface('Paper border',w+0.16,h+0.16,-0.004,(0.81,0.78,0.70))
solid = paper.modifiers.new('Paper thickness','SOLIDIFY')
solid.thickness = 0.007
photo,mat = surface('Photograph',w,h,0,(1,1,1))
nodes = mat.node_tree.nodes
nodes.clear()
tex = nodes.new('ShaderNodeTexImage')
tex.image = image
emission = nodes.new('ShaderNodeEmission')
emission.inputs['Strength'].default_value = 1
output = nodes.new('ShaderNodeOutputMaterial')
mat.node_tree.links.new(tex.outputs['Color'], emission.inputs['Color'])
mat.node_tree.links.new(emission.outputs[0], output.inputs['Surface'])
bpy.ops.object.light_add(type='AREA',location=(-3,1,6))
light = bpy.context.object
light.name = 'Soft window light'
light.data.energy = 650
light.data.shape = 'DISK'
light.data.size = 5
light.rotation_euler = (Vector((0,0,0))-light.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.object.camera_add()
cam = bpy.context.object
cam.name = 'Photo insert camera'
cam.data.lens = 50
cam.data.sensor_width = 36
scene.camera = cam
# An image card keeps the original content coherent. Only physical camera motion
# and the paper/table relationship create depth; this is not inferred scene depth.
fit = max(w, h * cfg['width']/cfg['height']) * 50/36
near = fit*0.98
far = fit*1.45
move = cfg['move']
for frame in range(1, cfg['count']+1):
    t = (frame-1)/max(1,cfg['count']-1)
    ease = t*t*(3-2*t)
    z = near+(far-near)*ease
    x,y = 0.12*ease,0.16*ease
    if move == 'Slow push in':
        z = far+(near-far)*ease
        x,y = 0.12*(1-ease),0.16*(1-ease)
    elif move == 'Gentle orbit':
        z = fit*1.27
        x,y = 0.7*math.sin((ease-0.5)*0.65),0.45
    cam.location = (x,y,z)
    forward = (Vector((0,0,0))-cam.location).normalized()
    right = forward.cross(Vector((0,1,0))).normalized()
    up = right.cross(forward)
    cam.rotation_euler = Matrix((right,up,-forward)).transposed().to_euler()
    cam.keyframe_insert(data_path='location',frame=frame)
    cam.keyframe_insert(data_path='rotation_euler',frame=frame)
scene.frame_set(1)
scene.render.filepath = '//Frames/Frame-'
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=cfg['blend'])
for frame in range(1,cfg['count']+1):
    scene.frame_set(frame)
    scene.render.filepath = os.path.join(cfg['frames'], 'Frame-%05d.png'%frame)
    bpy.ops.render.render(write_still=True)
"""#
}
