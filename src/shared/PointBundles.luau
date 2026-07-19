export type PointBundle = {
	RobuxProductId: number,
	Points: number,
	Label: string, -- short, fits a narrow shop button
}

-- Straight Robux-for-Points, no gameplay tied to owning these (unlike
-- gamepasses) -- granted once per purchase via PurchaseService, same
-- idempotency-guard reasoning as GachaService's Robux pulls (see
-- PlayerDataService's ProcessedPurchaseIds comment).
local PointBundles: { PointBundle } = {
	{ RobuxProductId = 3610627363, Points = 1500, Label = "1.5K" },
	{ RobuxProductId = 3610627428, Points = 15000, Label = "15K" },
	{ RobuxProductId = 3610627521, Points = 100000, Label = "100K" },
}

return PointBundles
