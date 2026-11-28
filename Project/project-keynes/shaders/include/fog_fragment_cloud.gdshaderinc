		if (fog_amount > 0.02) {
			// thick 在未探索区收敛到 1；alpha 必须能真正到 1.0，否则 world_map
			// 的早退会露出底下未绘制的内容。
			float thick = smoothstep(0.52, 0.95, fog_amount);
			float presence = smoothstep(0.04, 0.52, fog_amount);

			// 噪声域尺度（已按环绕周期对齐到整数格）+ 该域下一个屏幕像素的跨度
			// （喂给 FBM 做 LOD 截断）。
			vec2 sc = fog_tileable_scale(1.0 / max(hex_world_diameter * cloud_scale, 0.001));
			float scale = sc.x;
			float period_n = sc.y;
			vec2 p = wp * scale;
			float lod_px = max(fwidth(v_world.x), fwidth(v_world.y)) * scale;

			vec3 col;
			float alpha;

			if (q <= 0) {
				// ── q0 超低：无导数、无光照。只要一层柔和起伏把纯色打散。
				vec2 q0_drift = vec2(t * 0.17, -t * 0.13);
				float n = fog_grad_noise_tiled_evolve(
					p + q0_drift, period_n, t, 9
				);
				float shade = mix(0.86, 1.14, n);
				col = mix(explored_color, unexplored_color, thick) * shade;
				float thin_a = explored_alpha * presence * mix(0.76, 1.10, n);
				alpha = mix(clamp(thin_a, 0.0, 1.0), 1.0, thick);
			} else {
				// q1 与 q2+ 都要 TOD，先算一次。
				vec2 map_uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));
				float lat_signed = clamp(map_uv.y * 2.0 - 1.0, -1.0, 1.0);
				EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);

				// ── 主光：太阳与月亮分别着色后平滑相加 ─────────────────
				// 旧版直接 step(日/月) 会在晨昏线上瞬间翻转法线受光与阴影方向。
				// 高空云在太阳落到地平线以下后仍能被照亮，所以太阳可见带也应比地表
				// local_day 更宽；这段额外宽度正是火烧云出现的区域。
				float sun_elev = ed.sun_dir.z;
				float cloud_day = day_night_enabled
					? smoothstep(-0.46, 0.34, sun_elev)
					: 1.0;
				float sun_strength = day_night_enabled
					? smoothstep(-0.42, 0.24, sun_elev)
					: 1.0;
				float twilight = smoothstep(-0.50, -0.02, sun_elev)
					* (1.0 - smoothstep(0.14, 0.56, sun_elev));
				float moon_strength = ed.moon_strength
					* (1.0 - smoothstep(0.18, 0.78, sun_strength));
				vec3 sun_key_col = ed.sun_col * sun_strength;
				float moon_luma = dot(ed.moon_col, vec3(0.2126, 0.7152, 0.0722));
				vec3 moon_cloud_col = mix(ed.moon_col, vec3(moon_luma), 0.38);
				vec3 moon_key_col = moon_cloud_col * moon_strength;
				vec3 key_col = sun_key_col + moon_key_col;
				float key_amt = clamp(sun_strength + moon_strength, 0.0, 1.0);
				float sun_share = sun_strength / max(sun_strength + moon_strength, 0.0001);

				vec3 sun_d = ed.sun_dir;
				sun_d.z = max(sun_d.z, 0.08);
				vec3 sun_L = normalize(sun_d);
				vec3 moon_d = ed.moon_dir;
				moon_d.z = clamp(moon_d.z, 0.08, 0.72);
				vec3 moon_L = normalize(moon_d);

				// 主光轴：方向性效果不再「翻转」，而是按日/月光强比连续混合。
				//   · 自阴影：永远沿太阳水平轴（全天连续）；深夜由 daylight_shadow
				//     压到 0.16，月轴阴影本就不可见 —— 切换它只会制造翻转线。
				//   · 轮廓光/暮光坡向：本模拟 moon_dir = -sun_dir，月轴恰为日轴
				//     镜像；对同一坡度分别算「向日/向月」两套权重按 use_sun_axis
				//     混合，50/50 处方向性自然中和 —— 数学上严格连续，无衰减缝。
				// 混合带刻意拉宽（±0.45 光强差 ≈ 整个晨昏区）：镜像混合本身严格连续，
				// 唯一可见残留是「权重互换太快」—— 带越宽，迎/背光坡的明暗互换
				// 越摊薄，肉眼越读不出这条带。昼/夜两端仍各自收敛到纯日/纯月。
				float use_sun_axis = smoothstep(-0.45, 0.45, sun_strength - moon_strength);
				float sun_hlen = length(sun_L.xy);
				vec2 sun_axis_s = (sun_hlen > 1e-3)
					? sun_L.xy / sun_hlen
					: normalize(vec2(0.62, -0.38));
				float moon_hlen = length(moon_L.xy);
				vec2 moon_axis_s = (moon_hlen > 1e-3) ? moon_L.xy / moon_hlen : -sun_axis_s;
				vec2 axis_blend = mix(moon_axis_s, sun_axis_s, use_sun_axis);
				float axis_len = length(axis_blend);
				float sun_horiz = clamp(mix(moon_hlen, sun_hlen, use_sun_axis), 0.0, 1.0);
				float sun_up = max(mix(moon_L.z, sun_L.z, use_sun_axis), 0.0);
				vec3 L = normalize(vec3((axis_blend / max(axis_len, 1e-4)) * sun_horiz, sun_up));

				// 屏幕空间假视差：正交俯视没有真视差，用屏幕位置近似视线方向。
				// 纯屏幕函数 ⇒ 三块 wrap 副本取值完全一致，不会在环绕接缝处错开；
				// 镜头平移 / 云特征横穿屏幕时，高层云相对低层剪切滑动。
				vec2 scr_uv = FRAGCOORD.xy * SCREEN_PIXEL_SIZE;
				float scr_aspect = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 1e-6);
				vec2 view_dir = (scr_uv - vec2(0.5)) * vec2(scr_aspect, 1.0) * 2.0;
				vec2 parallax_p = view_dir * parallax_strength * hex_world_diameter * scale;

				float cover = clamp(fog_amount * 1.15, 0.0, 1.0);
				vec2 pw = (q >= 2) ? fog_domain_warp(p, t, period_n, q) : p;
				FogCloudShape shape = fog_sample_shape(
					pw, t, period_n, lod_px, cover, q, parallax_p
				);

				// ── 光照 ───────────────────────────────────────────────
				vec3 N = normalize(vec3(
					-(
						shape.broad_grad * cloud_relief
						+ shape.detail_grad * cloud_detail_relief
					),
					1.0
				));
				float sun_ndl = dot(N, sun_L);
				float moon_ndl = dot(N, moon_L);
				// 动态包裹光：正午太阳近顶光，N·L 本身就平，给足包裹保持柔和；
				// 太阳越低光越擦着云丘走，包裹收紧 → 同一片云在晨昏出现强方向性
				// 明暗。这是「TOD 角度变化读得出来」的主要来源。
				float dyn_wrap = mix(0.42, light_wrap, smoothstep(-0.10, 0.55, sun_elev));
				float sun_diffuse = clamp((sun_ndl + dyn_wrap) / (1.0 + dyn_wrap), 0.0, 1.0);
				float moon_diffuse_raw = clamp(
					(moon_ndl + light_wrap) / (1.0 + light_wrap),
					0.0,
					1.0
				);
				// 月光漫反射不能完全压平：深夜它是唯一主光，全平会把夜云糊成一块
				// 纯色蓝布。保留中等方向性勾出云丘起伏，但仍远弱于太阳的方向性。
				float moon_diffuse = mix(0.62, moon_diffuse_raw, 0.42);

				// 云丘坡向（轮廓光/暮光共用）。注意符号：高度场梯度指向坡上，
				// 迎光坡的梯度指向**远离**太阳的一侧，即 edge_face < 0 才是迎光坡
				// （与 N·L 一致：N 的水平分量 = -grad）。
				vec2 slope_g = shape.broad_grad + shape.detail_grad * 0.40;
				float slope_len = length(slope_g);
				float edge_face = (slope_len > 1e-3)
					? dot(slope_g / slope_len, sun_axis_s)
					: 0.0;
				// 向日坡权重；向月坡是其精确镜像（moon_dir=-sun_dir ⇒ 1-sun_face_s）。
				// 按光强比混合后，晨昏线两侧同一面坡的受光权重连续过渡。
				float sun_face_s = clamp(0.5 - 0.5 * edge_face, 0.0, 1.0);
				float sun_face = mix(1.0 - sun_face_s, sun_face_s, use_sun_axis);

				// 自阴影积分的是前方云体质量。低处权重大、塔顶权重小，形成柔和厚度，
				// 但不再把「前方比我高」直接画成黑色峡谷。
				float horizon_mass = 0.0;
				if (q >= 2 && shadow_reach > 0.001) {
					// 固定 2 探针：近端 f=0.5 决定阴影形状，远端 f=1.0 提供厚度。
					// 软阴影模型下第 3 段远探针的贡献肉眼不可辨。
					float reach = (shadow_reach / max(cloud_scale, 0.001))
						* clamp(sun_horiz / max(sun_up, 0.28), 0.35, 3.0);
					for (int i = 0; i < 2; i++) {
						float f = float(i + 1) * 0.5;
						float mass = fog_shadow_mass(
							pw + sun_axis_s * (reach * f),
							t,
							period_n,
							lod_px,
							cover
						);
						horizon_mass += mass * (1.0 - 0.32 * f);
					}
					horizon_mass *= 0.5;
				}
				float local_mass = clamp(shape.body * 0.72 + shape.top * 0.28, 0.0, 1.0);
				float excess_mass = max(0.0, horizon_mass - local_mass * 0.58);
				float directional_mass = mix(horizon_mass, excess_mass, 0.62);
				float valley_weight = mix(0.92, 0.32, shape.height);
				float optical_shadow = directional_mass * valley_weight * shadow_absorb;
				// 日光消失后不能让质量阴影恢复到满强度：真实夜云主要由天空/月光
				// 扩散照亮，深夜只留下很弱的厚度遮蔽（0.16 下限）。
				float daylight_shadow = smoothstep(0.08, 0.72, sun_strength);
				// 阴影轴全天固定为太阳水平轴（见主光轴注释），场天然连续，
				// 不再需要任何翻转线遮蔽；twilight 只做轻微压暗。
				float shadow_strength = mix(0.16, 1.0, daylight_shadow)
					* mix(1.0, 0.62, twilight);
				optical_shadow *= shadow_strength;
				float light_t = (q >= 2) ? cloud_beer_ms(optical_shadow) : 1.0;
				float density = max(shape.deck * 0.55, shape.body);
				float powder = (q >= 2) ? cloud_powder(density, powder_weight) : 1.0;

				// 银边只落在中层云体的软边，不再覆盖整块低层云海。
				float body_edge = smoothstep(0.05, 0.42, shape.body)
					* (1.0 - smoothstep(0.56, 0.96, shape.body));
				float sun_silver = 0.0;
				float moon_silver = 0.0;
				if (q >= 2) {
					sun_silver = cloud_phase(sun_L.z, phase_g) * body_edge * light_t
						* smoothstep(-0.10, 0.70, sun_ndl) * silver_gain;
					moon_silver = cloud_phase(moon_L.z, phase_g) * body_edge * light_t
						* smoothstep(-0.10, 0.70, moon_ndl) * silver_gain * 0.16;
				}

				vec3 tint_n = shadow_tint
					/ max(dot(shadow_tint, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
				// 地表晨昏只需在太阳几何落山附近过渡；高空云仍能看见地平线下的
				// 散射光，因此单独使用更宽的 cloud_day，不能直接照搬 ed.amb_col。
				// 夜侧环境光先抬亮、去饱和：EARTH_NIGHT_AMBIENT 是给地形剪影用的
				// 深蓝，直接照云会得到一块饱和死蓝布；真实夜云是被月光与天光
				// 照亮的暗灰蓝，内部仍有可读起伏。
				vec3 night_amb = mix(
					EARTH_NIGHT_AMBIENT,
					vec3(dot(EARTH_NIGHT_AMBIENT, vec3(0.2126, 0.7152, 0.0722))),
					0.35
				) * 1.28;
				vec3 cloud_ambient_col = mix(
					night_amb,
					EARTH_DAY_AMBIENT,
					cloud_day
				);
				// EARTH_NIGHT_AMBIENT 本身已经偏蓝；深夜若再完整叠 shadow_tint，
				// 会双重染蓝成水下色。夜侧只保留少量冷色偏移，白昼再恢复完整 tint。
				vec3 cloud_tint = mix(vec3(1.0), tint_n, mix(0.22, 1.0, cloud_day));
				vec3 sky_col = cloud_ambient_col * cloud_tint;
				float sky = mix(valley_sky, 1.0, shape.height);
				vec3 ambient = sky_col * sky * ambient_gain;
				if (q >= 3) {
					vec3 sky_N = normalize(vec3(
						-shape.broad_grad * cloud_relief * 0.34,
						1.0
					));
					vec3 key_palette = mix(moon_cloud_col, ed.sun_col, sun_share);
					float sky_key_amt = key_amt * mix(0.20, 1.0, sun_share);
					ambient = earth_sky_sh(sky_col, key_palette, L, sky_key_amt, sky_N)
						* sky * ambient_gain;
				}
				float moon_fill_strength = moon_strength
					* (1.0 - smoothstep(0.12, 0.62, sun_strength));
				ambient += moon_cloud_col * moon_fill_strength
					* mix(0.085, 0.125, shape.height);

				// 多重散射用厚尾有理式；越深越从主光色漂向冷天光。
				float ms_depth = (1.0 - shape.height) * 0.55
					+ shape.thickness * 0.28
					+ optical_shadow * 0.10;
				float tint_t = clamp(ms_depth * shadow_tint_depth, 0.0, 1.0);
				vec3 bounce_col = mix(
					key_col,
					sky_col * mix(0.72, 1.0, key_amt),
					tint_t
				);
				vec3 bounce = bounce_col * (ms_gain / (1.0 + ms_falloff * ms_depth));

				float sss = (q >= 2)
					? exp(-shape.thickness * 2.2) * light_t * body_edge * sss_gain
					: 0.0;
			vec3 direct = sun_key_col * (
				sun_diffuse * light_t * powder * sun_gain + sun_silver
				) + moon_key_col * (
					moon_diffuse * light_t * mix(1.0, powder, 0.35) * sun_gain * 0.36
					+ moon_silver
				);

				// 高度 AO：云缝谷底比云顶少吃直射与反弹 —— 明暗落差是体积感的另一半。
				// 只压直射/反弹，不动天空环境光，谷底仍被天光托住，不会死黑。
				direct *= mix(1.0 - ao_strength * 0.90, 1.0, shape.height);
				bounce *= mix(1.0 - ao_strength * 0.55, 1.0, shape.height);

				// 暮光穿过更长的大气路径后偏金橙；只落在**朝向太阳**的坡面、云塔
				// 与软边上。不带朝向的 fire_mask 会把晨昏带均匀刷成一圈描边光晕
				// （像贴上去的）；低角度阳光没有道理照亮背光坡。
				float fire_warmth = smoothstep(-0.16, 0.12, sun_elev);
				vec3 fire_color = mix(
					vec3(1.38, 0.56, 0.05),
					vec3(1.28, 0.96, 0.18),
					fire_warmth
				);
				float fire_mask = twilight * (
					shape.deck * 0.03
					+ shape.body * 0.15
					+ shape.top * 0.30
					+ body_edge * 0.26
				);
				fire_mask *= mix(0.22, 1.0, sun_face) * mix(0.55, 1.0, sun_diffuse);
				vec3 fire_scatter = fire_color * fire_mask * (0.13 + light_t * 0.12);

				// 三层不能共用一套「albedo × light」：那只是在一张表面上换颜色，
				// 法线再强也没有前后层次。低层以天光/回填为主，中层吃柔和直射，
				// 云顶获得最强直射与最弱深度衰减，再按嵌套密度从下往上合成。
				vec3 deck_albedo = deck_color;
				vec3 body_albedo = mix(deck_color, cloud_albedo, 0.68);
				vec3 top_albedo = cloud_albedo;
				float warm_albedo = twilight * clamp(
					shape.body * 0.12 + shape.top * 0.23 + body_edge * 0.18,
					0.0,
					0.34
				);
				// 与 fire_scatter 同向：暖色反照率只染迎光侧，背光侧保持冷灰。
				warm_albedo *= mix(0.45, 1.0, sun_face);
				body_albedo = mix(body_albedo, vec3(1.0, 0.72, 0.25), warm_albedo * 0.72);
				top_albedo = mix(top_albedo, vec3(1.0, 0.82, 0.38), warm_albedo);

				vec3 deck_light = ambient * 1.08 + bounce * 1.04 + direct * 0.30;
				vec3 body_light = ambient * 0.96 + bounce * 0.90 + direct * 0.82;
				vec3 top_light = ambient * 1.02 + bounce * 0.68 + direct * 1.20;
				float body_depth = shape.body * (1.0 - shape.top) * (0.35 + optical_shadow * 0.18);
				vec3 deck_radiance = deck_albedo * deck_light;
				vec3 body_radiance = body_albedo * body_light * mix(1.0, 0.84, body_depth);
				vec3 top_radiance = top_albedo * top_light * mix(1.0, 1.07, shape.top);
				float body_w = smoothstep(0.04, 0.92, shape.body) * 0.86;
				float top_w = smoothstep(0.03, 0.90, shape.top) * 0.82;

				// 低层只用柔和天光托底；这是未探索区完全遮挡时仍像云海、而不是
				// 黑色空洞的关键。它是加法散射，不是逐像素 max() 硬地板。
				vec3 deck_fill = sky_col * (0.08 + shape.veil * 0.10);
				col = mix(deck_radiance, body_radiance, body_w);
				col = mix(col, top_radiance, top_w)
					+ deck_fill
					+ fire_scatter
					+ key_col * (sss * 0.24 + shape.top * 0.055);

				// 坡向轮廓光（q2+）：迎光坡提亮、背光坡微压（迎光坡 = edge_face < 0）。
				// 向日/向月两套轮廓权重互为镜像，按 use_sun_axis 混合：翻转线上
				// 迎/背权重相等、方向性自然中和 —— 严格连续，无衰减缝。
				// 太阳越低轮廓光越强（掠射角拉长迎光坡），正午收敛。
				if (q >= 2) {
					float rim_band = smoothstep(0.06, 0.38, slope_len)
						* clamp(shape.body * 0.55 + shape.top * 0.75, 0.0, 1.0);
					float rim_strength = mix(0.25, 1.0, key_amt)
						* mix(1.35, 1.0, smoothstep(-0.05, 0.60, sun_elev))
						* mix(0.45, 1.0, sun_share);
					float rim_pos_sun = smoothstep(0.15, 0.85, -edge_face) * rim_band;
					float rim_neg_sun = smoothstep(0.15, 0.85, edge_face) * rim_band;
					float rim_pos = mix(rim_neg_sun, rim_pos_sun, use_sun_axis);
					float rim_neg = mix(rim_pos_sun, rim_neg_sun, use_sun_axis);
					col = col * (1.0 - rim_neg * 0.16 * rim_strength)
						+ key_col * (rim_pos * rim_gain * 0.55 * rim_strength);
				}

				// 夜侧整体调光：深夜（cloud_day=0）乘 night_darkness，白昼不变。
				col *= mix(night_darkness, 1.0, cloud_day);
				col = fog_soft_tonemap(col);
				// S 曲线把被 ACES 压平的中间调重新拉开：亮云顶更挺、暗云缝更沉。
				// 夜侧强度略降：深夜只剩环境光，满强度 S 曲线仍会把夜云压死黑。
				col = mix(
					col,
					col * col * (3.0 - 2.0 * col),
					volume_contrast * mix(0.65, 1.0, cloud_day)
				);
				col *= mix(0.94, 1.06, clamp(shape.body * 0.45 + shape.top * 0.55, 0.0, 1.0));

				// 过渡带按分层云体透明；满迷雾区仍严格 alpha=1，保证玩法信息不泄漏。
				float cloud_opacity = clamp(
					shape.veil * 0.38
					+ shape.deck * 0.40
					+ shape.body * 0.18
					+ shape.top * 0.08,
					0.0,
					1.0
				);
				float thin_a = explored_alpha * presence * mix(0.16, 1.0, cloud_opacity);
				alpha = mix(clamp(thin_a, 0.0, 1.0), 1.0, thick);
			}

#ifdef PK_CELL_FIELD
			// ── 约束 3 的落地（方案 §3.6 / §6 不变量 1）────────────────────────
			// 地形早退的像素在地形 program 里被写成 `fog_unexplored_color` 常量色，
			// 迷雾**必须**在这里画满，否则玩家会透过迷雾看到那块纯色。
			// 用 mix 而不是 if：三元/混合在 GPU 上是无分支选择，逐像素分支会让这一行
			// 落进非一致控制流（本函数后面还有 fwidth 的消费者，方案 §3.9 第 3 条）。
			alpha = mix(alpha, 1.0, fog_hidden01);
#endif
			out_color = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha, 0.0, 1.0));
		}
