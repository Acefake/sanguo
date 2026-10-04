shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform sampler2DArray albedo_layers : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray normal_layers : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float wind_strength = 0.025;
uniform float layer_count = 1.0;
varying flat vec2 texture_layer;
void vertex() {
    texture_layer = vec2(round(UV2.x*(layer_count-1.0)),UV2.y);
    vec3 world = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
    float weight = smoothstep(0.05,5.0,VERTEX.y);
    VERTEX.x += sin(TIME*1.1+world.x*0.13+world.z*0.17)*weight*wind_strength;
    VERTEX.z += cos(TIME*0.8+world.x*0.11)*weight*wind_strength*0.7;
}
void fragment() {
    vec4 leaf = texture(albedo_layers,vec3(UV,texture_layer.x));
    ALBEDO = leaf.rgb;
    ALPHA = leaf.a;
    ALPHA_SCISSOR_THRESHOLD = 0.35;
    ROUGHNESS = 0.9;
    SPECULAR = 0.18;
    if(texture_layer.y > 0.5) {
        NORMAL_MAP = texture(normal_layers,vec3(UV,texture_layer.x)).rgb;
        NORMAL_MAP_DEPTH = 0.6;
    }
    BACKLIGHT = leaf.rgb*0.12;
}
