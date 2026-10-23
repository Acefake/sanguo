shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D pose_positions : filter_nearest, repeat_disable;
uniform sampler2D pose_normals : filter_nearest, repeat_disable;
uniform float animation_clock = 0.0;
uniform int pose_rows = 1;
uniform bool mounted_palette = false;
uniform bool reference_archer = false;
uniform vec4 cloth_color : source_color = vec4(0.73,0.65,0.39,1.0);
varying float uniform_height;
uniform int pose_start = 0;
uniform int pose_count = 1;
uniform float pose_rate = 0.0;
uniform int previous_start = 0;
uniform int previous_count = 1;
uniform float previous_rate = 0.0;
uniform float transition_at = -1.0;
// Contact facing, one set per formation material (army_world_3d/animation.gd _publish_facing).
// Yaws are world space, atan(x, z), up to 4 fronts; a set of 0 fronts means the formation's own +Z.
// Each soldier takes the front nearest its offset from formation_origin and turns from its heading
// in facing_from to the one in facing_goal at turn_rate (rad/s of animation_clock).
uniform vec4 facing_from = vec4(0.0);
uniform int facing_from_count = 0;
uniform vec4 facing_goal = vec4(0.0);
uniform int facing_goal_count = 0;
uniform float facing_at = -100.0;
uniform float turn_rate = 3.5;
uniform vec2 formation_origin = vec2(0.0);
// Feet center in model space: soldiers turn and fall around it.
uniform vec3 pivot = vec3(0.0);
// Melee contact. contact_cell: xz center of the formation's hex and the radius of its incircle; front ranks
// within push_band m of that edge (beyond their lunge reach) close on it, and every soldier's lunge stops
// contact_gap m short of it. contact_window: animation_clock when the melee began and ended.
uniform vec3 contact_cell = vec3(0.0);
uniform vec2 contact_window = vec2(-100.0, -99.0);
uniform float lunge_reach = 0.0;
// Half the widest combat pose across the heading, model units: both flanks of the lunge must clear the edge.
uniform float lunge_width = 0.0;
uniform float push_band = 2.2;
uniform float contact_gap = 0.2;
// 1 while an enemy melee front strikes this formation: its front ranks rock back on the enemy's beat.
uniform float under_attack = 0.0;
// Fallen soldiers carry INSTANCE_CUSTOM.w = -(death time - death_epoch) - 10; alive ones a value >= 0.
uniform float death_epoch = 0.0;
varying float fade;

// Integer `%` and `/` by a uniform divisor are avoided throughout: llvmpipe's JIT emits an illegal
// instruction for them on CPUs without AVX, which takes down the GL compatibility renderer.
vec3 pose_sample(sampler2D atlas, int frame, int index) {
 int width = textureSize(atlas, 0).x;
 int row = int((float(index) + 0.5) / float(width));
 return texelFetch(atlas, ivec2(index - row * width, frame * pose_rows + row), 0).xyz;
}

// The yaw in `yaws` whose direction best matches `offset` (unit or zero), or `fallback` for an empty set.
float nearest_front(vec4 yaws, int count, vec2 offset, float fallback, out float score) {
 score = -2.0;
 float yaw = fallback;
 for (int k = 0; k < 4; k++) {
  if (k >= count) break;
  float s = dot(offset, vec2(sin(yaws[k]), cos(yaws[k])));
  if (s > score) { score = s; yaw = yaws[k]; }
 }
 return yaw;
}

vec3 turn_y(vec3 v, float angle) {
 float c = cos(angle);
 float s = sin(angle);
 return vec3(v.x * c + v.z * s, v.y, v.z * c - v.x * s);
}

// Distance from `rel` (relative to a circle's center, inside it) along unit `dir` to the circle; -1 outside.
float edge_distance(vec2 rel, vec2 dir, float radius) {
 float along = dot(rel, dir);
 float inside = dot(rel, rel) - radius * radius;
 return inside < 0.0 ? sqrt(along * along - inside) - along : -1.0;
}

// Positive angles tip +Y toward +Z (pitch) and toward -X (roll).
vec3 turn_x(vec3 v, float angle) {
 float c = cos(angle);
 float s = sin(angle);
 return vec3(v.x, v.y * c - v.z * s, v.y * s + v.z * c);
}

vec3 turn_z(vec3 v, float angle) {
 float c = cos(angle);
 float s = sin(angle);
 return vec3(v.x * c - v.y * s, v.x * s + v.y * c, v.z);
}

void vertex() {
 uniform_height = pose_sample(pose_positions, 0, VERTEX_ID).y;
 if (mounted_palette) uniform_height = (uniform_height - 0.85) / 1.05;
 vec3 world_pivot = (MODEL_MATRIX * vec4(pivot, 1.0)).xyz;
 float formation_yaw = atan(MODEL_MATRIX[2].x, MODEL_MATRIX[2].z);
 vec2 offset = world_pivot.xz - formation_origin;
 offset = dot(offset, offset) > 1e-8 ? normalize(offset) : vec2(0.0);
 float score;
 float from_score;
 float goal = nearest_front(facing_goal, facing_goal_count, offset, formation_yaw, score);
 float start = nearest_front(facing_from, facing_from_count, offset, formation_yaw, from_score);
 float limit = turn_rate * max(animation_clock - facing_at, 0.0);
 float yaw = start + clamp(mod(goal - start + PI, TAU) - PI, -limit, limit);
 // How squarely this soldier stands on its front: rear ranks swing at partial strength.
 float weight = facing_goal_count > 0 ? clamp(score, 0.0, 1.0) : INSTANCE_CUSTOM.z;

 fade = 1.0;
 float fall = 0.0;
 float sink = 0.0;
 if (INSTANCE_CUSTOM.w < 0.0) {
  float age = animation_clock - (death_epoch - INSTANCE_CUSTOM.w - 10.0);
  fall = smoothstep(0.0, 0.45, age);
  sink = smoothstep(0.55, 1.3, age);
  fade = 1.0 - sink;
 }
 // Melee strikes are staggered: each soldier its own phase (x) and rate (y), front ranks (z) faster.
 // Archers keep the plain rate: their arrows are timed to it (combat_effects_3d.gd show_archer_volley).
 float rate = pose_start == 9 && !reference_archer ? (0.8 + INSTANCE_CUSTOM.y * 0.4) * mix(0.82, 1.18, INSTANCE_CUSTOM.z) : 0.92 + INSTANCE_CUSTOM.y * 0.16;
 float previous_jitter = previous_start == 9 && !reference_archer ? (0.8 + INSTANCE_CUSTOM.y * 0.4) * mix(0.82, 1.18, INSTANCE_CUSTOM.z) : 0.92 + INSTANCE_CUSTOM.y * 0.16;
 float frame = mod(animation_clock * pose_rate * rate + INSTANCE_CUSTOM.x * float(pose_count), float(pose_count));
 int a = pose_start + int(floor(frame));
 int b = int(floor(frame)) + 1 < pose_count ? a + 1 : pose_start;
 float t = fract(frame);
 float activity = (pose_start == 9 ? mix(0.45, 1.0, weight) : 1.0) * (1.0 - fall);
 vec3 animated_position = mix(pose_sample(pose_positions, a, VERTEX_ID), pose_sample(pose_positions, b, VERTEX_ID), t);
 vec3 animated_normal = normalize(mix(pose_sample(pose_normals, a, VERTEX_ID), pose_sample(pose_normals, b, VERTEX_ID), t));
 VERTEX = mix(pose_sample(pose_positions, 0, VERTEX_ID), animated_position, activity);
 NORMAL = normalize(mix(pose_sample(pose_normals, 0, VERTEX_ID), animated_normal, activity));
 if (animation_clock - transition_at < 0.18) {
 float previous_frame = mod(transition_at * previous_rate * previous_jitter + INSTANCE_CUSTOM.x * float(previous_count), float(previous_count));
 int pa = previous_start + int(floor(previous_frame));
 int pb = int(floor(previous_frame)) + 1 < previous_count ? pa + 1 : previous_start;
 float previous_weight = previous_start == 9 ? mix(0.45, 1.0, weight) : 1.0;
 vec3 previous_position = mix(pose_sample(pose_positions, 0, VERTEX_ID), mix(pose_sample(pose_positions, pa, VERTEX_ID),pose_sample(pose_positions, pb, VERTEX_ID),fract(previous_frame)), previous_weight);
 vec3 previous_normal = mix(pose_sample(pose_normals, 0, VERTEX_ID), mix(pose_sample(pose_normals, pa, VERTEX_ID),pose_sample(pose_normals, pb, VERTEX_ID),fract(previous_frame)), previous_weight);
 float blend = smoothstep(0.0, 0.18, animation_clock - transition_at);
 VERTEX = mix(previous_position, VERTEX, blend);
 NORMAL = normalize(mix(previous_normal, NORMAL, blend));
 }
 // Front ranks close on the hex edge while the melee lasts; any soldier whose lunge would cross it steps back.
 float model_scale = length(MODEL_MATRIX[0].xyz);
 vec2 heading = vec2(sin(yaw), cos(yaw));
 bool lunging = pose_start == 9 || (previous_start == 9 && animation_clock - transition_at < 0.18);
 float engage = smoothstep(contact_window.x, contact_window.x + 0.5, animation_clock) * (1.0 - smoothstep(contact_window.y, contact_window.y + 0.6, animation_clock));
 float advance = 0.0;
 float front = 0.0;
 if (contact_cell.z > 0.0 && (lunging || engage > 0.0)) {
  vec2 side = vec2(heading.y, -heading.x) * lunge_width * model_scale;
  float to_edge = min(edge_distance(world_pivot.xz + side - contact_cell.xy, heading, contact_cell.z),
   edge_distance(world_pivot.xz - side - contact_cell.xy, heading, contact_cell.z));
  if (to_edge >= 0.0) {
   float reach = lunge_reach * model_scale;
   front = 1.0 - smoothstep(reach + 0.3, reach + push_band, to_edge);
   float room = (to_edge - reach - contact_gap) * front;
   advance = min(room, 0.0) * (lunging ? 1.0 : engage) + max(room, 0.0) * engage;
  }
 }
 // Struck front ranks rock back on the enemy's beat (combat cycle, offset from their own swing).
 float beat = fract(animation_clock * 6.5 / 12.0 + INSTANCE_CUSTOM.x + 0.37);
 float hit = under_attack * engage * front * (1.0 - fall) * smoothstep(0.0, 0.06, beat) * (1.0 - smoothstep(0.06, 0.4, beat));

 float local_yaw = yaw - formation_yaw;
 vec3 local = VERTEX - pivot;
 vec3 normal = NORMAL;
 local = turn_x(local, -hit * 0.14);
 normal = turn_x(normal, -hit * 0.14);
 if (mounted_palette) {
  local = turn_z(local, fall * 1.35);
  normal = turn_z(normal, fall * 1.35);
 } else {
  local = turn_x(local, -fall * 1.45);
  normal = turn_x(normal, -fall * 1.45);
 }
 vec3 forward = vec3(sin(local_yaw), 0.0, cos(local_yaw));
 VERTEX = turn_y(local, local_yaw) + pivot + (forward * (advance - hit * 0.14) - vec3(0.0, sink * 0.7, 0.0)) / model_scale;
 NORMAL = turn_y(normal, local_yaw);
}
void fragment() {
 if (fade < 0.999) {
  // Screen-door fade (interleaved gradient noise) keeps the opaque pipeline.
  float noise = fract(52.9829189 * fract(dot(floor(FRAGCOORD.xy), vec2(0.06711056, 0.00583715))));
  if (noise >= fade) discard;
 }
 vec4 tex = texture(albedo_texture, UV);
 ALBEDO = tex.rgb * COLOR.rgb;
 // Field uniforms use the reference's ochre cloth and red waist sash.
 // Horse coat and native texture detail remain sampled from the recovered atlas.
 if (reference_archer && UV.x < 0.5 && distance(COLOR.rgb,vec3(1.0)) > 0.1) {
  float light = dot(tex.rgb,vec3(0.299,0.587,0.114));
  ALBEDO = COLOR.rgb * (0.65 + light * 1.1);
 }
 if (!reference_archer && (!mounted_palette || (UV.x >= 0.5 && UV.y >= 0.5))) {
  float light = dot(tex.rgb,vec3(0.299,0.587,0.114));
  vec3 cloth = cloth_color.rgb * (0.55 + light * 2.0);
  // Keep native skin, armour, helmet and spear pixels readable. The previous
  // full-body 62% wash made the recovered UV texture look like plain clay.
  ALBEDO = mix(ALBEDO,cloth,0.12);
  float sash = smoothstep(0.93,0.97,uniform_height) * (1.0 - smoothstep(1.10,1.14,uniform_height));
  ALBEDO = mix(ALBEDO,vec3(0.40,0.065,0.033)*(0.7+light),sash*0.35);
 }
 ROUGHNESS = 0.82;
 METALLIC = 0.08;
}
