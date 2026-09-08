/* GPL-2.0-or-later. Conservative columns for the legacy truncated distance.
 * Keep one extra luxel on each edge: (int)distance truncates toward zero.
 * The original per-luxel predicate still decides whether to add the light.
 */
#ifndef REF_LIGHT_BOUNDS_H
#define REF_LIGHT_BOUNDS_H
static void
R_LightColumns(float center, float radius, int width, int *first, int *end)
{
	float lo = (center - radius - 1.0f) * (1.0f / 16.0f);
	float hi = (center + radius + 1.0f) * (1.0f / 16.0f);
	*first = lo <= 0 ? 0 : (lo >= width ? width : (int)lo);
	*end = hi < 0 ? 0 : (hi >= width - 1 ? width : (int)hi + 1);
}
#endif
