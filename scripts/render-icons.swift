import AppKit
let destination = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
func stroke(_ points:[NSPoint],width:CGFloat,color:NSColor) {
    let p=NSBezierPath(); p.move(to:points[0]); for point in points.dropFirst(){p.line(to:point)}
    p.lineWidth=width;p.lineCapStyle = .round;p.lineJoinStyle = .round;color.setStroke();p.stroke()
}
func mark(_ box:NSRect,template:Bool) {
    let center=NSPoint(x:box.midX,y:box.midY), radius=box.width*0.34
    let mint=template ? NSColor.black : NSColor(srgbRed:0.27,green:0.91,blue:0.73,alpha:1)
    let arc=NSBezierPath();arc.appendArc(withCenter:center,radius:radius,startAngle:40,endAngle:315,clockwise:false)
    arc.lineWidth=box.width*0.105;arc.lineCapStyle = .round;mint.setStroke();arc.stroke()
    stroke([NSPoint(x:center.x+radius*0.7071,y:center.y-radius*0.7071),NSPoint(x:center.x+radius*1.03,y:center.y-radius*1.07)],width:box.width*0.105,color:mint)
    // A tiny command prompt associates the quota ring with a coding tool.
    stroke([NSPoint(x:center.x-box.width*0.07,y:center.y+box.width*0.10),NSPoint(x:center.x+box.width*0.055,y:center.y),NSPoint(x:center.x-box.width*0.07,y:center.y-box.width*0.10)],width:box.width*0.052,color:template ? .black : .white)
}
func render(size:Int,app:Bool,file:String) throws {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let scale=CGFloat(size)/1024
    let transform=AffineTransform(scale:scale); (transform as NSAffineTransform).concat()
    NSColor.clear.setFill();NSRect(x:0,y:0,width:1024,height:1024).fill()
    if app {
        let background=NSBezierPath(roundedRect:NSRect(x:38,y:38,width:948,height:948),xRadius:211,yRadius:211)
        let gradient=NSGradient(starting:NSColor(srgbRed:0.10,green:0.21,blue:0.23,alpha:1),ending:NSColor(srgbRed:0.035,green:0.075,blue:0.105,alpha:1))!
        gradient.draw(in:background,angle:270)
        NSColor.white.withAlphaComponent(0.08).setStroke();background.lineWidth=3;background.stroke()
        mark(NSRect(x:170,y:170,width:684,height:684),template:false)
    } else { mark(NSRect(x:5,y:5,width:1014,height:1014),template:true) }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(file))
}
let iconset=destination.appendingPathComponent("AppIcon.iconset",isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for n in [16,32,128,256,512] {
    try render(size:n,app:true,file:"AppIcon.iconset/icon_\(n)x\(n).png")
    try render(size:n*2,app:true,file:"AppIcon.iconset/icon_\(n)x\(n)@2x.png")
}
try render(size:1024,app:true,file:"AppIcon.png")
try render(size:128,app:true,file:"BrandMark.png")
try render(size:18,app:false,file:"StatusIcon.png")
try render(size:36,app:false,file:"StatusIcon@2x.png")
