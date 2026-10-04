shader_type spatial;
render_mode cull_disabled;
uniform sampler2D shore_texture : filter_linear_mipmap, repeat_disable;
uniform bool has_shore = false;
uniform vec4 map_bounds = vec4(-70.0,-70.0,260.0,260.0);
varying vec3 world_position;
float hash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float noise(vec2 p) {
    vec2 i=floor(p); vec2 f=fract(p); f=f*f*(3.0-2.0*f);
    return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);
}
void vertex() { world_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }
void fragment() {
    vec2 p=world_position.xz;
    float broad=noise(p*vec2(0.25,0.60)+vec2(TIME*0.035,0));
    float ripple=noise(p*vec2(1.1,2.7)+vec2(TIME*0.1,TIME*0.07));
    float shine=smoothstep(0.62,0.83,broad*0.65+ripple*0.35);
    vec3 water=mix(vec3(0.045,0.041,0.035),vec3(0.20,0.19,0.17),shine*0.52);
    if(has_shore) {
        float coast=1.0-smoothstep(0.0,0.18,texture(shore_texture,(p-map_bounds.xy)/map_bounds.zw).r);
        water=mix(water,vec3(0.27,0.26,0.23),coast*smoothstep(0.38,0.70,ripple)*0.50);
    }
    ALBEDO=water;
    NORMAL_MAP=normalize(vec3((ripple-0.5)*0.22,(broad-0.5)*0.22,1.0))*0.5+0.5;
    ROUGHNESS=0.42;
    SPECULAR=0.32;
}
