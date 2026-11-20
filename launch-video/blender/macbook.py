"""Builds a MacBook Pro-like laptop procedurally and renders it with the app on its screen.

blender -b -P macbook.py -- --screen <image or movie> --out <path> [--shot hero|reveal|front] [--frames a b]
                             [--samples N] [--res 3840 2160] [--still FRAME]

Units are centimetres (scene scale 0.01). No external models or textures.
"""
import bpy, bmesh, math, sys, os
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default=None, n=1):
    if name in argv:
        i = argv.index(name)
        return argv[i + 1] if n == 1 else argv[i + 1:i + 1 + n]
    return default

SCREEN = arg("--screen")
OUT = arg("--out", "/tmp/macbook.png")
SHOT = arg("--shot", "hero")
STILL = arg("--still")
FRAMES = arg("--frames", None, 2)
RES = [int(x) for x in arg("--res", ["3840", "2160"], 2)]
SAMPLES = int(arg("--samples", "64"))
FINISH = arg("--finish", "silver")  # silver | black

# ---------------------------------------------------------------- scene
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'
scene.unit_settings.scale_length = 0.01
scene.render.engine = 'BLENDER_EEVEE_NEXT' if 'BLENDER_EEVEE_NEXT' in [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties['engine'].enum_items] else 'BLENDER_EEVEE'
scene.render.resolution_x, scene.render.resolution_y = RES
scene.render.fps = 60
scene.render.film_transparent = False
ee = scene.eevee
for attr, val in [("taa_render_samples", SAMPLES), ("use_raytracing", True), ("use_shadows", True),
                  ("shadow_ray_count", 2), ("shadow_step_count", 8), ("use_gtao", True)]:
    if hasattr(ee, attr):
        try: setattr(ee, attr, val)
        except Exception: pass
if hasattr(ee, "ray_tracing_options"):
    try:
        ee.ray_tracing_options.resolution_scale = '1'
        ee.ray_tracing_method = 'SCREEN'
    except Exception: pass
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast' if 'AgX - Medium High Contrast' in [i.identifier for i in scene.view_settings.bl_rna.properties['look'].enum_items_static] else 'None'

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs[0].default_value = (0.0035, 0.0038, 0.006, 1)
bg.inputs[1].default_value = 1.0

# ---------------------------------------------------------------- helpers
def rounded_rect(w, d, r, seg=12):
    pts = []
    cs = [(w / 2 - r, d / 2 - r, 0), (-w / 2 + r, d / 2 - r, 90), (-w / 2 + r, -d / 2 + r, 180), (w / 2 - r, -d / 2 + r, 270)]
    for cx, cy, a0 in cs:
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def slab(name, w, d, h, r, bevel=0.12, seg=12):
    """A rounded-rectangle slab from z=0 to z=h, with softened edges."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    vs = [bm.verts.new((x, y, 0)) for x, y in rounded_rect(w, d, r, seg)]
    f = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    top = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=top, vec=(0, 0, h))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    if bevel > 0:
        m = ob.modifiers.new("bevel", 'BEVEL')
        m.width = bevel; m.segments = 4; m.limit_method = 'ANGLE'; m.angle_limit = math.radians(50)
        m.harden_normals = True
    for p in me.polygons: p.use_smooth = True
    if hasattr(me, "set_sharp_from_angle"):
        me.set_sharp_from_angle(angle=math.radians(40))
    return ob

def mat(name, color, metallic=0.0, rough=0.4, aniso=0.0, emission=None, strength=1.0, coat=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    if "Anisotropic" in b.inputs: b.inputs["Anisotropic"].default_value = aniso
    if "Coat Weight" in b.inputs: b.inputs["Coat Weight"].default_value = coat
    if emission is not None:
        b.inputs["Emission Color"].default_value = (*emission, 1)
        b.inputs["Emission Strength"].default_value = strength
    return m

def assign(ob, m):
    ob.data.materials.clear(); ob.data.materials.append(m)

# ---------------------------------------------------------------- materials
if FINISH == "black":
    alu = mat("Aluminum", (0.035, 0.036, 0.04), metallic=1.0, rough=0.38, aniso=0.2)
else:
    alu = mat("Aluminum", (0.72, 0.725, 0.74), metallic=1.0, rough=0.3, aniso=0.25)
alu_dark = mat("WellAlu", (0.5, 0.505, 0.52) if FINISH != "black" else (0.03, 0.03, 0.035), metallic=1.0, rough=0.45)
keycap = mat("Keycap", (0.012, 0.012, 0.014), rough=0.55)
glass_black = mat("Bezel", (0.002, 0.002, 0.0025), rough=0.32)
glass_black.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.12
pad = mat("Trackpad", (0.62, 0.625, 0.64) if FINISH != "black" else (0.04, 0.04, 0.045), metallic=1.0, rough=0.38)
floor_m = mat("Floor", (0.002, 0.0021, 0.003), rough=0.22)
rubber = mat("Rubber", (0.01, 0.01, 0.01), rough=0.8)

# Screen: emission from the capture (image or movie), plus a thin glossy glass layer on top.
screen_m = bpy.data.materials.new("Screen")
screen_m.use_nodes = True
nt = screen_m.node_tree
for n in list(nt.nodes): nt.nodes.remove(n)
out = nt.nodes.new("ShaderNodeOutputMaterial")
mix = nt.nodes.new("ShaderNodeMixShader")
em = nt.nodes.new("ShaderNodeEmission")
gloss = nt.nodes.new("ShaderNodeBsdfPrincipled")
gloss.inputs["Base Color"].default_value = (0, 0, 0, 1)
gloss.inputs["Roughness"].default_value = 0.04
gloss.inputs["Specular IOR Level"].default_value = 0.35 if "Specular IOR Level" in gloss.inputs else 0.5
fres = nt.nodes.new("ShaderNodeLayerWeight")
fres.inputs["Blend"].default_value = 0.08
tex = nt.nodes.new("ShaderNodeTexImage")
tex.interpolation = 'Cubic'
if SCREEN and os.path.exists(SCREEN):
    img = bpy.data.images.load(SCREEN)
    if SCREEN.lower().endswith((".mov", ".mp4", ".m4v")):
        img.source = 'MOVIE'
        tex.image_user.frame_duration = img.frame_duration
        tex.image_user.use_auto_refresh = True
        tex.image_user.frame_start = 1
    tex.image = img
    img.colorspace_settings.name = 'sRGB'
nt.links.new(tex.outputs["Color"], em.inputs["Color"])
em.inputs["Strength"].default_value = 1.25
nt.links.new(fres.outputs["Fresnel"], mix.inputs[0])
nt.links.new(em.outputs[0], mix.inputs[1])
nt.links.new(gloss.outputs[0], mix.inputs[2])
nt.links.new(mix.outputs[0], out.inputs[0])

# ---------------------------------------------------------------- the laptop
W, D = 31.26, 22.12          # 14-inch footprint
BASE_H, LID_H = 1.0, 0.55
R = 1.05
base = slab("Base", W, D, BASE_H, R, bevel=0.22, seg=16)
assign(base, alu)
# Feet
for sx in (-1, 1):
    for sy in (-1, 1):
        f = slab("Foot", 1.6, 1.6, 0.12, 0.8, bevel=0.03, seg=8)
        f.location = (sx * (W / 2 - 2.2), sy * (D / 2 - 2.2), -0.11)
        assign(f, rubber)

# Keyboard well and keys
well_w, well_d = 27.6, 11.4
well = slab("Well", well_w, well_d, 0.05, 0.5, bevel=0.0, seg=8)
well.location = (0, D / 2 - 1.3 - well_d / 2, BASE_H - 0.02)
assign(well, keycap)
key, gap = 1.62, 0.19
rows = [14, 14, 14, 13, 12, 10]
y0 = D / 2 - 1.6 - key * 0.35
for ri, n in enumerate(rows):
    h = key * (0.55 if ri == 0 else 1.0)
    y = y0 - sum((key * (0.55 if i == 0 else 1.0) + gap) for i in range(ri)) - h / 2
    total = well_w - 1.0
    kw = (total - gap * (n - 1)) / n
    for k in range(n):
        x = -total / 2 + kw / 2 + k * (kw + gap)
        if ri == 5 and k == n // 2:  # space bar
            continue
        c = slab("Key", kw, h, 0.09, 0.18, bevel=0.03, seg=4)
        c.location = (x, y, BASE_H)
        assign(c, keycap)
    if ri == 5:
        sb = slab("Space", kw * 4 + gap * 3, h, 0.09, 0.18, bevel=0.03, seg=4)
        sb.location = (0, y, BASE_H)
        assign(sb, keycap)
# Trackpad
tp = slab("Trackpad", 15.0, 9.4, 0.02, 0.6, bevel=0.0, seg=10)
tp.location = (0, -D / 2 + 1.2 + 4.7, BASE_H - 0.01)
assign(tp, pad)

# Lid, hinged along the back edge, built lying flat then rotated.
hinge = bpy.data.objects.new("Hinge", None)
bpy.context.collection.objects.link(hinge)
hinge.location = (0, D / 2 - 0.35, BASE_H + 0.05)
lid = slab("Lid", W, D, LID_H, R, bevel=0.2, seg=16)
assign(lid, alu)
lid.parent = hinge
lid.location = (0, -D / 2 + 0.35, 0)           # back edge at the hinge
lid.rotation_euler = (0, 0, 0)
# Inner face: black glass bezel and the display.
bezel = slab("BezelGlass", W - 0.25, D - 0.25, 0.03, R - 0.12, bevel=0.0, seg=16)
bezel.parent = lid
bezel.location = (0, 0, -0.045)
assign(bezel, glass_black)
DISP_W = 30.2
disp_h = DISP_W * 1964 / 3024   # the 14-inch panel's aspect (3024 x 1964)
bpy.ops.mesh.primitive_plane_add(size=1)
disp = bpy.context.active_object
disp.name = "Display"
disp.scale = (DISP_W, disp_h, 1)
bpy.ops.object.transform_apply(scale=True)
disp.parent = lid
disp.location = (0, -0.32, -0.05)
disp.rotation_euler = (math.pi, 0, 0)         # face down (inner side), flip so the image isn't mirrored
assign(disp, screen_m)
# Camera housing (notch)
notch = slab("Notch", 3.0, 0.75, 0.02, 0.3, bevel=0.0, seg=6)
notch.parent = lid
notch.location = (0, -0.32 - disp_h / 2 + 0.36, -0.06)
assign(notch, glass_black)

OPEN = math.radians(float(arg("--open", "112")))
hinge.rotation_euler = (-OPEN, 0, 0)

# ---------------------------------------------------------------- floor and lights
bpy.ops.mesh.primitive_plane_add(size=600, location=(0, 0, -0.12))
floor = bpy.context.active_object
assign(floor, floor_m)

def area(name, loc, rot, size, energy, color=(1, 1, 1), shape='RECTANGLE', size_y=None):
    l = bpy.data.lights.new(name, 'AREA')
    l.shape = shape
    l.size = size
    if size_y: l.size_y = size_y
    l.energy = energy
    l.color = color
    o = bpy.data.objects.new(name, l)
    o.location = loc
    o.rotation_euler = [math.radians(a) for a in rot]
    bpy.context.collection.objects.link(o)
    return o

# Key: large soft box above and in front-left. Rims: thin strips behind on both sides to draw the edges.
area("Key", (-60, -70, 110), (35, 0, -35), 120, 260000, (1.0, 0.98, 0.96), size_y=80)
area("RimL", (-70, 55, 30), (-70, 0, -130), 140, 160000, (0.85, 0.9, 1.0), size_y=12)
area("RimR", (70, 55, 30), (-70, 0, 130), 140, 160000, (1.0, 0.93, 0.85), size_y=12)

# Softboxes the metal can reflect: emissive cards the camera never sees directly.
def softbox(name, loc, rot, sx, sy, strength, color=(1, 1, 1)):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = (sx, sy, 1)
    o.rotation_euler = [math.radians(a) for a in rot]
    m = mat(name + "M", (0, 0, 0), emission=color, strength=strength)
    assign(o, m)
    o.visible_camera = False
    o.visible_shadow = False
    return o
softbox("BoxTop", (0, -10, 90), (0, 0, 0), 120, 70, 6.0)
softbox("BoxFront", (0, -140, 40), (75, 0, 0), 160, 40, 2.5)
softbox("BoxLeft", (-110, 0, 40), (0, -70, 0), 50, 120, 2.0, (0.9, 0.94, 1.0))
softbox("BoxRight", (110, 0, 40), (0, 70, 0), 50, 120, 2.0, (1.0, 0.95, 0.9))

# ---------------------------------------------------------------- camera
cam_data = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_data)
bpy.context.collection.objects.link(cam)
scene.camera = cam
target = bpy.data.objects.new("Target", None)
bpy.context.collection.objects.link(target)
con = cam.constraints.new('TRACK_TO')
con.target = target
con.track_axis = 'TRACK_NEGATIVE_Z'
con.up_axis = 'UP_Y'
cam_data.sensor_width = 36
cam_data.dof.use_dof = True
cam_data.dof.focus_object = target
cam_data.dof.aperture_fstop = 4.0

# Screen centre in world space (for framing).
bpy.context.view_layer.update()
screen_centre = disp.matrix_world.translation.copy()

def key(obj, frame, loc):
    obj.location = loc
    obj.keyframe_insert("location", frame=frame)

def ease_all(obj):
    if obj.animation_data and obj.animation_data.action:
        act = obj.animation_data.action
        curves = getattr(act, "fcurves", None)
        if curves is None:
            try:
                curves = [fc for layer in act.layers for strip in layer.strips for cb in strip.channelbags for fc in cb.fcurves]
            except Exception:
                curves = []
        for fc in curves:
            for kp in fc.keyframe_points:
                kp.interpolation = 'BEZIER'
                kp.easing = 'EASE_IN_OUT'

if SHOT == "reveal":
    # Starts inside the screen (the beam fills the frame), pulls back to a 3/4 hero.
    cam_data.lens = 50
    n = int(arg("--length", "300"))
    s = screen_centre
    normal = (disp.matrix_world.to_3x3() @ Vector((0, 0, -1))).normalized() * -1
    key(target, 1, s); key(target, n, (0, 2.0, 9.0))
    key(cam, 1, s + normal * 24 + Vector((0, 0, 0)))
    key(cam, n, (34, -66, 34))
    scene.frame_start, scene.frame_end = 1, n
    ease_all(cam); ease_all(target)
elif SHOT == "front":
    cam_data.lens = 70
    n = int(arg("--length", "300"))
    key(target, 1, (0, 3, 10.5)); key(target, n, (0, 3, 9.5))
    key(cam, 1, (0, -88, 26)); key(cam, n, (0, -104, 28))
    scene.frame_start, scene.frame_end = 1, n
    ease_all(cam); ease_all(target)
else:  # hero still
    cam_data.lens = 55
    target.location = (0, 2.0, 9.0)
    cam.location = (36, -70, 34)
    scene.frame_start = scene.frame_end = 1

# ---------------------------------------------------------------- render
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_depth = '16' if STILL else '8'
if STILL or SHOT == "hero":
    scene.frame_set(int(STILL or 1))
    scene.render.filepath = OUT
    bpy.ops.render.render(write_still=True)
else:
    if FRAMES:
        scene.frame_start, scene.frame_end = int(FRAMES[0]), int(FRAMES[1])
    scene.render.filepath = OUT  # e.g. /path/frame_####
    bpy.ops.render.render(animation=True)
print("done", OUT)
