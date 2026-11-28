		// 保留旧 11 参数 ABI，避免 ShaderInclude 热缓存与主 shader 热重载不同步。
		// 气候参数仅用于接口兼容，global_adjustments 内不再消费它们。
		// 13 = 陆/水分支判定。用户报告的现象是「所有格子都像被一层水面渲染覆盖」，
		// 这一档直接把 is_water 的取值画出来，并按具体水 biome 分色，一眼区分成因：
		//   绿   = 走陆地管线（正常陆地）
		//   白   = B_SEA_ICE。cid<0 时 biome 被无条件赋成它，所以整片白 = 索引失效
		//   蓝   = B_OCEAN，即 enum_lut.r 读成 0
		//   青/深蓝/品红/黄 = COAST / LAKE / REEF / KELP
		// 14 = flow（河流 SDF）。灰阶=原始取值，红=已越过 river_threshold_low，也就是
		// land_pipeline 会把该像素混上河水色的区域。正常应当是接近全黑的底图上几条细红
		// 河线；整屏发白/发红即 flow 采样器落到 GLES3 兜底白纹理（Legacy 应读 height_tex）。
		// 刻意读未经 has_flow_tex 门控的 flow_raw：门控已经把管线侧的故障挡住了，这一档
		// 要能继续报出"纹理其实没绑"这件事，否则修复会把诊断一起掩盖掉。
		if (terrain_surface_debug_view == 14) {
			float f = clamp(flow_raw, 0.0, 1.0);
			vec3 fv = vec3(f);
			if (f >= river_threshold_low) { fv = vec3(1.0, 0.0, 0.0); }
			COLOR = vec4(fv, 1.0);
		} else if (terrain_surface_debug_view == 16) {
			// 16 = flow 所在采样器尺寸（height_tex / visual_height_tiles），
			// 以 12 位二进制条读出（0..4095）。
			// 上半屏 = 宽，下半屏 = 高；左边是最高位，白=1、深蓝=0，每 4 位一条红分隔。
			// 读出 derived_size = 正常；读出 4×4 = 采样器落到了引擎默认白纹理。
			// tests/_tmp_decode_texsize_view.gd 可以直接从截图里把这两个数解出来。
			ivec2 fs = visual_flow_texture_size();
			int val = (SCREEN_UV.y < 0.5) ? fs.x : fs.y;
			int bit = clamp(11 - int(floor(SCREEN_UV.x * 12.0)), 0, 11);
			vec3 c = (((val >> bit) & 1) == 1) ? vec3(1.0) : vec3(0.05, 0.05, 0.20);
			if (bit % 4 == 3 && fract(SCREEN_UV.x * 12.0) < 0.08) {
				c = vec3(1.0, 0.0, 0.0);
			}
			COLOR = vec4(c, 1.0);
		} else if (terrain_surface_debug_view == 17) {
			// 17 = 用 texelFetch 整数取样 flow，绕过 filter_linear 与 wrap uv。
			// 若这一档恢复出细红河线而 14 仍整屏红，问题在过滤/采样状态而非纹理内容。
			float f = clamp(visual_flow_texel(uv), 0.0, 1.0);
			vec3 fv = vec3(f);
			if (f >= river_threshold_low) { fv = vec3(1.0, 0.0, 0.0); }
			COLOR = vec4(fv, 1.0);
		} else if (terrain_surface_debug_view == 13) {
			vec3 branch = vec3(0.0, 1.0, 0.0);
			if (biome == B_SEA_ICE) { branch = vec3(1.0); }
			else if (biome == B_OCEAN) { branch = vec3(0.0, 0.25, 1.0); }
			else if (biome == B_COAST) { branch = vec3(0.0, 0.9, 0.9); }
			else if (biome == B_LAKE) { branch = vec3(0.0, 0.0, 0.5); }
			else if (biome == B_REEF) { branch = vec3(1.0, 0.0, 1.0); }
			else if (biome == B_KELP) { branch = vec3(1.0, 0.9, 0.0); }
			COLOR = vec4(branch, 1.0);
		} else if (terrain_surface_debug_view == 11 || terrain_surface_debug_view == 12
				|| terrain_surface_debug_view == 15) {
			// 11 = 光照后、apply_global_adjustments 前；12 = 光照前的底色；
			// 15 = 河流 flow 层之前的静态材质底色（三者都在 land_pipeline 里取值）。
			COLOR = vec4(col, 1.0);
#ifdef PK_CELL_FIELD
		// ── [cell-field 2026-11-18] 18–21：解析格界的四档诊断（方案 §5 P1 完成判据）。
		// 都只在 PK_CELL_FIELD 变体里存在（需要场函数），除 18/21 各多一次扭曲场采样
		// 之外没有新增采样，且都在 uniform 分支（terrain_surface_debug_view）内。
		} else if (terrain_surface_debug_view == 18) {
			// 18 = dom 一致性（tools/cell_field_gpu_probe.gd 读这一档）：绿 = 一致，红 = 不一致。
			//   用**两条独立路径**复算归属并对撞：
			//     A（场函数）：对偶三角形重心 argmax ⇒ dom；
			//     B（本档）：把三格的 offset 反解成 hex 中心（offset→axial→世界坐标，
			//       即 pk_axial_to_offset 与分数 axial 的逆运算），取像素到三个中心的
			//       欧氏距离最近者。
			//   两条路径的中间步骤完全不同（重心 vs offset 换算 + 世界距离），所以这一档
			//   能抓到 pk_axial_to_offset / pk_posmod 回绕 / padding 判定的错 —— 正是与
			//   CPU cube_round 做 parity 时最容易漂的那一层。格界带上可红可绿（亚像素 +
			//   平局次序），其余区域必须全绿。
			//   本变体**不读**索引图（契约 §6 的 grep 断言）；「dom vs 烘焙 cell id」的
			//   另一半由 CPU 侧的 hex_cell_field_parity_test.gd 守着：GPU 这半证明 shader
			//   场函数自洽，CPU 那半证明镜像 == 烘焙索引。
			vec2 field_pw = wrap_world_pos(wp + pk_boundary_warp_world(wp));
			vec2 field_ctr0 = pk_offset_hex_center(cell_field.c0);
			vec2 field_ctr1 = pk_offset_hex_center(cell_field.c1);
			vec2 field_ctr2 = pk_offset_hex_center(cell_field.c2);
			// offset col 已被 posmod 到 [0, map_w)，而 pw.x 是回绕后的世界坐标（可能为负），
			// 所以按 wrap_period_x 把中心平移回离像素最近的那一份；只有真正回绕时才做。
			if (wrap_period_x > 0.0001) {
				field_ctr0.x += wrap_period_x * round((field_pw.x - field_ctr0.x) / wrap_period_x);
				field_ctr1.x += wrap_period_x * round((field_pw.x - field_ctr1.x) / wrap_period_x);
				field_ctr2.x += wrap_period_x * round((field_pw.x - field_ctr2.x) / wrap_period_x);
			}
			float field_dd0 = length(field_pw - field_ctr0);
			float field_dd1 = length(field_pw - field_ctr1);
			float field_dd2 = length(field_pw - field_ctr2);
			int field_nearest = (field_dd0 <= field_dd1 && field_dd0 <= field_dd2) ? 0
					: ((field_dd1 <= field_dd2) ? 1 : 2);
			COLOR = vec4((field_nearest == cell_field.dom)
					? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), 1.0);
		} else if (terrain_surface_debug_view == 19) {
			// 19 = 三格锐化权重 w 直接当 RGB（R=c0 G=c1 B=c2）。三格交汇处应是三色
			// 平滑过渡；出现黑线/白线说明 w 的归一化或 band 有问题（方案 §3.2 接缝）。
			COLOR = vec4(cell_field.w, 1.0);
		} else if (terrain_surface_debug_view == 20) {
			// 20 = 解析格距 vs 烘焙 edge_distance.R 的差值（契约 §6：gap < 0.86 区间内
			// |Δ| < 0.02）。灰阶 = |Δ|×25（0.02 → 0.5 亮度），|Δ| > 0.04 直接标红。
			// 全黑 = 两条数据源一致；整屏红 = 单位或坐标口径错（例如把 world 单位当 gap，
			// 或 warp 没生效）。scals.r 在 PK 下就是 pk_cell_field_edge_gap()。
			// 复用 SETUP 那一次 edge_distance 采样（不新增采样点）。
#ifdef VT_USE_EDGE_DISTANCE
			float field_gap_err = abs(edge_px.r - scals.r);
			vec3 field_gap_col = vec3(clamp(field_gap_err * 25.0, 0.0, 1.0));
			if (field_gap_err > 0.04) { field_gap_col = vec3(1.0, 0.0, 0.0); }
#else
			vec3 field_gap_col = vec3(scals.r);
#endif
			COLOR = vec4(field_gap_col, 1.0);
		} else if (terrain_surface_debug_view == 21) {
			// 21 = 扭曲场可视化：pk_boundary_warp_world(wp) 归一到 [-1,1] 后映射到 [0,1]
			// 打 RG（0.5 = 无扭曲）。整屏死灰 = layer6 / tiled warp tile 没绑
			// （terrain_warp_layer_bound=false），此时格界退化成直边六边形但归属仍正确。
			// 本档多一次扭曲场采样（场函数初始化已经采过一次）。
			vec2 field_warp_vis = pk_boundary_warp_world(wp)
					/ max(hex_size * terrain_warp_amp * terrain_warp_range, 1e-4);
			COLOR = vec4(field_warp_vis * 0.5 + 0.5, 0.0, 1.0);
		} else if (terrain_surface_debug_view == 22) {
			// 22 = dom 格的 offset 编码 —— **GPU ↔ CPU 逐像素回读比对专用**
			//   （tests/world/cell_field_gpu_parity_probe.gd 解码后与
			//     DCHexCellField.dom_at() 逐像素对撞；这是唯一能证明"GPU 与 CPU 用的是
			//     同一个坐标系"的通道，见 review 2026-11-18「没有任何测试验证 GPU 和
			//     CPU 用的是同一个坐标系」）。
			//   R,G = col 的低 / 高字节，B = row 的低字节，每个通道 byte/255。
			//   A = **常量 1.0**。
			// 为什么 A 不放 row 的高字节：本程序是 `render_mode blend_mix`（第 8 行），
			// 片元 alpha = 0 时 MIX 的 `dst = src.rgb·src.a + dst·(1−src.a)` 会把 rgb
			// 一起乘成 0，回读就是一片清屏色（实测：整个视图等于 viewport 的 clear
			// color，且与"什么都没画"无法区分）—— 编码必须让 alpha 非 0 才可回读。
			// row ∈ [0, 255) 时高字节本来就是 0，所以本视图对 col ∈ [0, 4095]、
			// row ∈ [0, 255] **仍然是无损的**；row 越界（padding 行 / 超 255）时高位
			// 会被截断，仅供目视诊断，不要拿它做数值比对。
			// 零新增采样：pk_cell_field_dom_offset 只复用 SETUP 已算好的场。
			ivec2 field_enc_c = pk_cell_field_dom_offset(cell_field);
			COLOR = vec4(
					float(field_enc_c.x & 255) / 255.0,
					float((field_enc_c.x >> 8) & 255) / 255.0,
					float(field_enc_c.y & 255) / 255.0,
					1.0);
		} else if (terrain_surface_debug_view == 23) {
			// 23 = **实际使用**的锐化带宽 band（灰阶 = band / PK_FIELD_BAND_MAX）。
			//   band = clamp(max(terrain_ecotone_width, AA 项), 1e-4, 0.86)，
			//   AA 项 = 2/hex_size · max(|fwidth(v_world)|) · terrain_edge_screen_width_px()。
			// 全图均匀灰 = AA 项主导且没有导数爆点；**经线接缝那一列整列变白（= 1.0）
			// 说明导数取在了已回绕坐标上**——review 2026-11-18 第 1 条的病征。
			// 本档是那条 bug 的回归信号：terrain_ecotone_width 调到足够小后，
			// max(band) 应该只剩 AA 项的量级（探针 Pass C 断言 < 0.10）。
			// 零新增采样（band 是场函数里已经算出来的局部量，只是额外存进 struct）。
			COLOR = vec4(vec3(cell_field.band / PK_FIELD_BAND_MAX), 1.0);
#endif // PK_CELL_FIELD
		} else if (terrain_surface_debug_view > 0) {
			COLOR = vec4(terrain_surface_debug_color(uv, wp, _cell_id), 1.0);
		} else {
#ifdef PK_PROBE_NO_GLOBAL_ADJ
			COLOR = vec4(col, 1.0);   // [probe] global_adjustments
#else
			COLOR = apply_global_adjustments(
				col, wp, pixel_noise, dyn_snow, current_temp, moist, dyn_vitality, dyn_valid,
				visual_surface_cover, is_water ? 0.0 : 1.0,
				visual_surface_veg == V_NONE ? 0.0 : 1.0);
#endif // PK_PROBE_NO_GLOBAL_ADJ
		}
	}
