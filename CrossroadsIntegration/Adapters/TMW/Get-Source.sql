set transaction isolation level read uncommitted
set deadlock_priority -10
set nocount on
declare @ReadThrough datetime = coalesce(convert(datetime, @Through), getdate())
declare @ReadFrom datetime = coalesce(convert(datetime, @From), dateadd(minute, -55, @ReadThrough))
if @ReadThrough <= @ReadFrom
begin
	;throw 50000, 'Through must be after From.', 1;
end
declare @Source nvarchar(max)

;with changed as (
	select
		  o.ord_hdrnumber
		, a.updated_date
	from
		orderheader o
		outer apply (
			select
				[updated_date] = max(v.updated_date)
			from
				stops s
				cross apply (
					values
						  (o.last_updatedate)
						, (s.last_updatedate)
						, (s.last_updatedatedepart)
				) v(updated_date)
			where
				s.ord_hdrnumber = o.ord_hdrnumber
		) a
	where
		o.ord_billto = @BillTo
		and (@Division is null or o.ord_revtype1 = @Division)
		and a.updated_date >= @ReadFrom
		and a.updated_date < @ReadThrough
)
select @Source = (select
	  [order_number]    = o.ord_hdrnumber
	, [source_status]   = o.ord_status
	, [progress_status] = case when o.ord_status = 'STD' then 'driving_to_load' else 'assigned' end
	, [created_date]    = convert(varchar(23), cast(o.ord_bookdate at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [updated_date]    = c.updated_date
	, [site_id]         = d.cmp_id
	, [site_name]       = rtrim(con.cmp_name)
	, [site_state]      = rtrim(con.cmp_state)
	, [product_id]      = f.cmd_code
	, [product_name]    = rtrim(f.fgt_description)
	, [supplier_id]     = f.fgt_supplier
	, [supplier_name]   = rtrim(sup.cmp_name)
	, [terminal_id]     = f.fgt_shipper
	, [terminal_name]   = rtrim(shp.cmp_name)
	, [volume]          = f.fgt_quantity
	, [window_start]    = convert(varchar(23), cast(d.stp_schdtearliest at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [window_end]      = convert(varchar(23), cast(d.stp_schdtlatest at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [delivery_eta]    = convert(varchar(23), cast(d.stp_arrivaldate at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [lift_arrive]     = convert(varchar(23), cast(l.stp_arrivaldate at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [lift_depart]     = convert(varchar(23), cast(l.stp_departuredate at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [lift_status]     = l.stp_status
	, [drop_arrive]     = convert(varchar(23), cast(d.stp_arrivaldate at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [drop_depart]     = convert(varchar(23), cast(d.stp_departuredate at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [drop_status]     = d.stp_status
	, [bol_number]      = bol.ref_number
	, [bol_date]        = convert(varchar(23), cast(coalesce(l.stp_departuredate, l.stp_arrivaldate) at time zone 'Eastern Standard Time' at time zone 'UTC' as datetime2(3)), 126) + 'Z'
	, [gross_volume]    = f.fgt_quantity
	, [net_volume]      = case when cmd.cmd_class in ('100', '200') then f.fgt_volume2 else f.fgt_weight end
from
	changed c
	join orderheader o on o.ord_hdrnumber = c.ord_hdrnumber
	join stops d on d.ord_hdrnumber = o.ord_hdrnumber and d.stp_event = 'LUL'
	left join company con on con.cmp_id = d.cmp_id
	join freightdetail f on f.stp_number = d.stp_number
	left join commodity cmd on cmd.cmd_code = f.cmd_code
	left join company shp on shp.cmp_id = f.fgt_shipper
	left join company sup on sup.cmp_id = f.fgt_supplier
	outer apply (
		select top (1)
			[ref_number] = rtrim(rn.ref_number)
		from
			referencenumber rn
		where
			rn.ord_hdrnumber = o.ord_hdrnumber
			and rn.ref_tablekey = f.fgt_number
			and rn.ref_table = 'freightdetail'
			and rn.ref_type = 'bol'
			and coalesce(rn.ref_number, '') != ''
		order by
			rn.ref_sequence
			, rn.ref_number
	) bol
	outer apply (
		select top (1)
			  s.stp_arrivaldate
			, s.stp_departuredate
			, s.stp_status
		from
			freightdetail pf
			join stops s on s.stp_number = pf.stp_number and s.stp_event = 'LLD'
		where
			pf.fgt_parentcmd_fgt_number = f.fgt_number
		order by
			s.stp_departuredate desc
	) pl
	outer apply (
		select top (1)
			  s.stp_arrivaldate
			, s.stp_departuredate
			, s.stp_status
		from
			stops s
		where
			s.ord_hdrnumber = o.ord_hdrnumber
			and s.stp_event = 'LLD'
		order by
			s.stp_sequence
	) ol
	cross apply (
		select
			  [stp_arrivaldate]   = coalesce(pl.stp_arrivaldate, ol.stp_arrivaldate)
			, [stp_departuredate] = coalesce(pl.stp_departuredate, ol.stp_departuredate)
			, [stp_status]        = coalesce(pl.stp_status, ol.stp_status)
	) l
order by
	o.ord_hdrnumber
	, f.fgt_number
for json path, include_null_values)
