shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D pose_positions : filter_nearest, repeat_disable;
uniform sampler2D pose_normals : filter_nearest, repeat_disable;
uniform float animation_clock = 0.0;
uniform int pose_start = 0;
uniform int pose_count = 1;
uniform float pose_rate = 0.0;
uniform int previous_start = 0;
uniform int previous_count = 1;
uniform float previous_rate = 0.0;
uniform float transition_at = -1.0;
void vertex() {
 float frame = mod(animation_clock * pose_rate * (0.92 + INSTANCE_CUSTOM.y * 0.16) + INSTANCE_CUSTOM.x * float(pose_count), float(pose_count));
 int a = pose_start + int(floor(frame));
 int b = pose_start + (int(floor(frame)) + 1) % pose_count;
 float t = fract(frame);
 float activity = pose_start == 9 ? mix(0.45, 1.0, INSTANCE_CUSTOM.z) : 1.0;
 vec3 animated_position = mix(texelFetch(pose_positions, ivec2(VERTEX_ID, a), 0).xyz, texelFetch(pose_positions, ivec2(VERTEX_ID, b), 0).xyz, t);
 vec3 animated_normal = normalize(mix(texelFetch(pose_normals, ivec2(VERTEX_ID, a), 0).xyz, texelFetch(pose_normals, ivec2(VERTEX_ID, b), 0).xyz, t));
 VERTEX = mix(texelFetch(pose_positions, ivec2(VERTEX_ID,0),0).xyz, animated_position, activity);
 NORMAL = normalize(mix(texelFetch(pose_normals, ivec2(VERTEX_ID,0),0).xyz, animated_normal, activity));
 if (animation_clock - transition_at < 0.18) {
 float previous_frame = mod(transition_at * previous_rate * (0.92 + INSTANCE_CUSTOM.y * 0.16) + INSTANCE_CUSTOM.x * float(previous_count), float(previous_count));
 int pa = previous_start + int(floor(previous_frame));
 int pb = previous_start + (int(floor(previous_frame)) + 1) % previous_count;
 float weight = previous_start == 9 ? mix(0.45, 1.0, INSTANCE_CUSTOM.z) : 1.0;
 vec3 previous_position = mix(texelFetch(pose_positions, ivec2(VERTEX_ID,0),0).xyz, mix(texelFetch(pose_positions,ivec2(VERTEX_ID,pa),0).xyz,texelFetch(pose_positions,ivec2(VERTEX_ID,pb),0).xyz,fract(previous_frame)), weight);
 vec3 previous_normal = mix(texelFetch(pose_normals, ivec2(VERTEX_ID,0),0).xyz, mix(texelFetch(pose_normals,ivec2(VERTEX_ID,pa),0).xyz,texelFetch(pose_normals,ivec2(VERTEX_ID,pb),0).xyz,fract(previous_frame)), weight);
 float blend = smoothstep(0.0, 0.18, animation_clock - transition_at);
 VERTEX = mix(previous_position, VERTEX, blend);
 NORMAL = normalize(mix(previous_normal, NORMAL, blend));
 }
}
void fragment() {
 vec4 tex = texture(albedo_texture, UV);
 ALBEDO = tex.rgb * COLOR.rgb;
 ROUGHNESS = 0.82;
 METALLIC = 0.08;
}
