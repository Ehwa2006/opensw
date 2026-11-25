shader_type canvas_item;
// 로봇 카메라 느낌: 배럴 왜곡, 색수차, 노이즈, 스캔라인, 비네팅, 글리치

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float glitch : hint_range(0.0, 1.0) = 0.0;
uniform float noise_amount = 0.05;

float rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 c = SCREEN_UV - 0.5;
	float r2 = dot(c, c);
	vec2 uv = 0.5 + c * (1.0 + 0.10 * r2);

	float line = floor(uv.y * 90.0);
	float tear = step(0.985 - glitch * 0.35, rand(vec2(line, floor(TIME * 14.0)))) * glitch;
	uv.x += (rand(vec2(line, TIME)) - 0.5) * 0.08 * tear;

	float ca = 0.0015 + glitch * 0.008;
	vec3 col;
	col.r = texture(screen_tex, uv + vec2(ca, 0.0)).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - vec2(ca, 0.0)).b;

	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(lum) * vec3(0.86, 1.0, 0.92), 0.45);
	col += (rand(SCREEN_UV * vec2(TIME * 0.7 + 1.0, TIME * 1.3 + 2.0)) - 0.5) * (noise_amount + glitch * 0.35);
	col *= 0.93 + 0.07 * sin(SCREEN_UV.y * 720.0 + TIME * 3.0);
	col *= smoothstep(0.95, 0.3, length(c) * 1.15);
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		col = vec3(0.0);
	}
	COLOR = vec4(col, 1.0);
}
