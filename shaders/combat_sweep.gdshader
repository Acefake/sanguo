shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
uniform sampler2D image : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 tint : source_color = vec4(0.75, 0.9, 1.0, 0.5);
uniform float sweep_angle = 1.57;
uniform float root_offset = 2.3;
void vertex() {
 MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
 // Texture narrow root sits at the army-side pivot; its fan opens toward the enemy.
 VERTEX.y += root_offset;
 VERTEX *= vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
 float c = cos(sweep_angle); float s = sin(sweep_angle);
 VERTEX.xy = mat2(vec2(c,s),vec2(-s,c)) * VERTEX.xy;
}
void fragment() {
 vec4 color = texture(image,UV);
 ALBEDO = color.rgb * tint.rgb;
 ALPHA = color.a * tint.a;
}
