shader_type spatial;
render_mode cull_back;

uniform sampler2D world_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D world_normal_texture : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D world_parameters : filter_linear_mipmap_anisotropic, repeat_disable;
// This PNG retains the source BGRA byte order. B,G,R are index,index,blend.
uniform sampler2D land_control : filter_nearest, repeat_disable;
uniform sampler2DArray terrain_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray terrain_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray terrain_parameters : filter_linear_mipmap_anisotropic, repeat_enable;
// x: native array slice; y/z: original TexScaleU/V; w: BlendSharpness.
uniform vec4 palette[18];
uniform float bilinear_rate = 0.5;
uniform vec2 near_far_blending = vec2(600.0, 750.0);
uniform vec4 map_bounds = vec4(0.0, 0.0, 2048.0, 2048.0);
varying vec3 world_position;
varying vec3 world_normal;
varying float view_distance;

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = MODEL_NORMAL_MATRIX * NORMAL;
    view_distance = length((VIEW_MATRIX * vec4(world_position, 1.0)).xyz);
}

void sample_layer(int index, vec2 plane, vec2 dx, vec2 dy,
                  out vec4 color, out vec4 normal_height, out vec4 parameters) {
    vec4 entry = palette[clamp(index, 0, 17)];
    vec3 uv = vec3(plane / entry.yz, entry.x);
    color = textureGrad(terrain_albedo, uv, dx / entry.yz, dy / entry.yz);
    normal_height = textureGrad(terrain_normal, uv, dx / entry.yz, dy / entry.yz);
    parameters = textureGrad(terrain_parameters, uv, dx / entry.yz, dy / entry.yz);
}

void sample_pair(vec3 control, float blend, vec2 plane, vec2 dx, vec2 dy,
                 out vec4 color, out vec4 normal_height, out vec4 parameters) {
    int primary = int(round(control.x * 255.0));
    int secondary = int(round(control.y * 255.0));
    if (secondary >= 18) {
        sample_layer(primary, plane, dx, dy, color, normal_height, parameters);
    } else if (control.z > 0.99) {
        sample_layer(secondary, plane, dx, dy, color, normal_height, parameters);
    } else {
        vec4 c0, n0, p0, c1, n1, p1;
        sample_layer(primary, plane, dx, dy, c0, n0, p0);
        sample_layer(secondary, plane, dx, dy, c1, n1, p1);
        // PB2LS-Gbi sharp blend: alpha is height, not normal strength.
        float h1 = n1.a + blend * 2.0 - 1.0;
        float floor_height = max(n0.a, h1) - (1.0 - palette[secondary].w);
        vec2 weights = max(vec2(n0.a, h1) - vec2(floor_height), vec2(0.0));
        float amount = weights.y / max(weights.x + weights.y, 0.00001);
        color = mix(c0, c1, amount);
        normal_height = mix(n0, n1, amount);
        parameters = mix(p0, p1, amount);
    }
}

void sample_plane(vec2 plane, vec2 dx, vec2 dy, vec3 a, vec3 b, vec3 c, vec3 d,
                  vec4 weights, float blend,
                  out vec4 color, out vec3 normal_height, out vec4 parameters) {
    vec4 ca, na, pa, cb, nb, pb, cc, nc, pc, cd, nd, pd;
    sample_pair(a, blend, plane, dx, dy, ca, na, pa);
    cb = ca; nb = na; pb = pa;
    cc = ca; nc = na; pc = pa;
    cd = ca; nd = na; pd = pa;
    if (any(notEqual(a, b))) sample_pair(b, blend, plane, dx, dy, cb, nb, pb);
    if (any(notEqual(a, c))) {
        if (all(equal(b, c))) { cc = cb; nc = nb; pc = pb; }
        else sample_pair(c, blend, plane, dx, dy, cc, nc, pc);
    }
    if (any(notEqual(a, d))) {
        if (all(equal(b, d))) { cd = cb; nd = nb; pd = pb; }
        else if (all(equal(c, d))) { cd = cc; nd = nc; pd = pc; }
        else sample_pair(d, blend, plane, dx, dy, cd, nd, pd);
    }
    color = ca*weights.x + cb*weights.y + cc*weights.z + cd*weights.w;
    normal_height = na.rgb*weights.x + nb.rgb*weights.y + nc.rgb*weights.z + nd.rgb*weights.w;
    parameters = pa*weights.x + pb*weights.y + pc*weights.z + pd*weights.w;
}

void fragment() {
    vec3 n = normalize(world_normal);
    vec2 map_uv = (world_position.xz - map_bounds.xy) / map_bounds.zw;
    vec4 color = texture(world_albedo, map_uv);
    vec3 detail = texture(world_normal_texture, map_uv).rgb;
    vec4 parameters = texture(world_parameters, map_uv);
    float far_amount = clamp((view_distance - near_far_blending.x) /
        (near_far_blending.y - near_far_blending.x), 0.0, 1.0);
    if (far_amount < 1.0) {
        vec3 dx = dFdx(world_position);
        vec3 dy = dFdy(world_position);
        vec2 point = clamp(map_uv * vec2(textureSize(land_control, 0) - ivec2(1)),
                          vec2(0.0), vec2(2047.9999));
        ivec2 cell = ivec2(floor(point));
        vec2 f = fract(point);
        vec4 weights = vec4((1.0-f.x)*(1.0-f.y), f.x*(1.0-f.y),
                            (1.0-f.x)*f.y, f.x*f.y);
        vec3 a = texelFetch(land_control, cell, 0).bgr;
        vec3 b = texelFetch(land_control, cell + ivec2(1,0), 0).bgr;
        vec3 c = texelFetch(land_control, cell + ivec2(0,1), 0).bgr;
        vec3 d = texelFetch(land_control, cell + ivec2(1,1), 0).bgr;
        float blend = dot(vec4(a.z,b.z,c.z,d.z), weights);
        // PB2LS blends projections using max(abs(normal)-threshold,0).
        // BilinearRate is mapped to the native cliff threshold provisionally;
        // its constant-buffer assignment still needs runtime confirmation.
        vec3 projections = max(abs(n) - vec3(bilinear_rate), vec3(0.0));
        float total = projections.x + projections.y + projections.z;
        if (total < 0.00001) {
            projections = vec3(0,1,0);
            if (abs(n.x) > abs(n.y) && abs(n.x) > abs(n.z)) projections = vec3(1,0,0);
            else if (abs(n.z) > abs(n.y)) projections = vec3(0,0,1);
        } else projections /= total;
        vec4 fine_color = vec4(0.0), fine_parameters = vec4(0.0), pc;
        vec3 fine_normal = vec3(0.0), pn;
        vec4 pp;
        if (projections.y > 0.0) {
            sample_plane(world_position.xz, dx.xz, dy.xz, a,b,c,d, weights,blend, pc,pn,pp);
            fine_color += pc * projections.y; fine_normal += pn * projections.y; fine_parameters += pp * projections.y;
        }
        if (projections.x > 0.0) {
            sample_plane(world_position.yz, dx.yz, dy.yz, a,b,c,d, weights,blend, pc,pn,pp);
            fine_color += pc * projections.x; fine_normal += pn * projections.x; fine_parameters += pp * projections.x;
        }
        if (projections.z > 0.0) {
            sample_plane(world_position.xy, dx.xy, dy.xy, a,b,c,d, weights,blend, pc,pn,pp);
            fine_color += pc * projections.z; fine_normal += pn * projections.z; fine_parameters += pp * projections.z;
        }
        color = mix(fine_color, color, far_amount);
        detail = mix(fine_normal, detail, far_amount);
        parameters = mix(fine_parameters, parameters, far_amount);
    }
    // PB2LS vertex output: tangent=(0,n.z,-n.y). Cliff projection
    // changes texture coordinates, while the native frame stays unchanged.
    vec3 tangent = normalize(vec3(0.0, n.z, -n.y));
    // dc52fd1c uses cross(tangent, normal), giving +X on flat ground.
    vec3 bitangent = normalize(cross(tangent, n));
    vec3 ts = normalize(detail * 2.0 - 1.0);
    vec3 surface_normal = normalize(n * ts.z + bitangent * ts.x + tangent * ts.y);
    NORMAL = normalize((VIEW_MATRIX * vec4(surface_normal, 0.0)).xyz);
    ALBEDO = color.rgb;
    AO = color.a;
    ROUGHNESS = parameters.a;
    SPECULAR = clamp(dot(parameters.rgb, vec3(0.333333)) / 0.08, 0.0, 1.0);
}
