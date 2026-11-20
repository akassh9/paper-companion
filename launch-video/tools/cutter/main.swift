import Foundation
import CoreImage

// cutter frame <t> <out.png>                 one frame of the film
// cutter frames <out-dir> t1 t2 ...          several frames
// cutter film <out.mov> [from s] [to s]      the edit, as ProRes 4K60

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: cutter frame <t> <out.png> | frames <dir> t... | film <out.mov> [from] [to]"); exit(1) }
switch args[1] {
case "frame":
    let t = Double(args[2])!
    writePNG(Timeline.frame(at: t, index: Int(t * Double(FPS))), args[3])
    print("wrote \(args[3])")
case "frames":
    let dir = args[2]
    for s in args[3...] {
        let t = Double(s)!
        let out = "\(dir)/f\(String(format: "%05.2f", t)).png"
        writePNG(Timeline.frame(at: t, index: Int(t * Double(FPS))), out)
        print("wrote \(out)")
    }
case "events":
    Timeline.exportEvents(args[2])
case "film":
    Timeline.renderFilm(to: args[2], from: args.count > 3 ? Double(args[3])! : 0, to: args.count > 4 ? Double(args[4])! : 1e9)
default:
    print("unknown command")
}
