///List of all items that can be found in the different types of order consoles, to purchase.
GLOBAL_LIST_EMPTY(order_console_products)

/obj/machinery/computer/order_console
	name = "Orders Console"
	desc = "An interface for ordering specific ingredients from Cargo, with an express option at the cost of more money."
	icon_screen = "request"
	icon_keyboard = "generic_key"
	light_color = LIGHT_COLOR_ORANGE

	///Cooldown between order uses.
	COOLDOWN_DECLARE(order_cooldown)
	///Cooldown time between uses, express console will have extra time depending on express_cost_multiplier.
	var/cooldown_time = 60 SECONDS
	///Boolean on whether they can bluespace orders using a '/obj/machinery/mining_ltsrbt'
	var/uses_ltsrbt = FALSE

	///The radio the console can speak into
	var/obj/item/radio/radio
	///The channel we will attempt to speak into through our radio.
	var/radio_channel = RADIO_CHANNEL_SUPPLY

	///Whether the console can only use express mode ONLY
	var/forced_express = FALSE
	///Multiplied cost to use express mode
	var/express_cost_multiplier = 2
	///The categories of orderable items this console can view and purchase.
	var/list/order_categories = list()
	///The current list of things we're trying to order, waiting for checkout.
	var/list/datum/orderable_item/grocery_list = list()

/obj/machinery/computer/order_console/Initialize(mapload)
	. = ..()
	radio = new(src)
	radio.set_frequency(FREQ_SUPPLY)
	radio.subspace_transmission = TRUE
	radio.canhear_range = 0
	radio.recalculateChannels()

	if(GLOB.order_console_products.len)
		return
	for(var/datum/orderable_item/path as anything in subtypesof(/datum/orderable_item))
		if(!initial(path.item_path))
			continue
		GLOB.order_console_products += new path

/obj/machinery/computer/order_console/Destroy()
	QDEL_NULL(radio)
	return ..()

/obj/machinery/computer/order_console/proc/get_total_cost()
	var/cost = 0
	for(var/datum/orderable_item/item as anything in grocery_list)
		cost += grocery_list[item] * item.cost_per_order
	return cost

/obj/machinery/computer/order_console/ui_interact(mob/user, datum/tgui/ui)
	. = ..()
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "ProduceConsole", name)
		ui.open()

/obj/machinery/computer/order_console/ui_data(mob/user)
	var/list/data = list()
	data["total_cost"] = get_total_cost()
	data["off_cooldown"] = COOLDOWN_FINISHED(src, order_cooldown)

	if(!isliving(user))
		return data
	var/mob/living/living_user = user
	var/obj/item/card/id/id_card = living_user.get_idcard(TRUE)
	if(id_card)
		data["points"] = id_card.registered_account?.account_balance

	return data

/obj/machinery/computer/order_console/ui_static_data(mob/user)
	var/list/data = list()
	data["ltsrbt_available"] = (uses_ltsrbt && GLOB.mining_ltsrbt.len)
	data["forced_express"] = forced_express
	data["order_categories"] = order_categories
	data["order_datums"] = list()
	for(var/datum/orderable_item/item as anything in GLOB.order_console_products)
		if(!(item.category_index in order_categories))
			continue
		data["order_datums"] += list(list(
			"name" = item.name,
			"desc" = item.desc,
			"cat" = item.category_index,
			"ref" = REF(item),
			"cost" = item.cost_per_order,
			"amt" = grocery_list[item],
		))
	return data

/obj/machinery/computer/order_console/ui_act(action, params)
	. = ..()
	if(.)
		return
	if(!isliving(usr))
		return
	var/mob/living/living_user = usr
	switch(action)
		if("cart_set")
			//this is null if the action doesn't need it (purchase, quickpurchase)
			var/datum/orderable_item/wanted_item = locate(params["target"]) in GLOB.order_console_products
			grocery_list[wanted_item] = clamp(params["amt"], 0, 20)
			if(!grocery_list[wanted_item])
				grocery_list -= wanted_item
			update_static_data(living_user)
		if("purchase", "ltsrbt_deliver")
			if(!grocery_list.len || !COOLDOWN_FINISHED(src, order_cooldown))
				return
			if(forced_express)
				return ui_act(action = "express")
			var/obj/item/card/id/used_id_card = living_user.get_idcard(TRUE)
			if(!used_id_card || !used_id_card.registered_account)
				say("No bank account detected!")
				return
			if(!purchase_items(used_id_card))
				return
			order_groceries(living_user, used_id_card, grocery_list, ltsrbt_delivered = (action == "ltsrbt_deliver"))
			grocery_list.Cut()
			COOLDOWN_START(src, order_cooldown, cooldown_time)
		if("express")
			if(!grocery_list.len || !COOLDOWN_FINISHED(src, order_cooldown))
				return
			var/obj/item/card/id/used_id_card = living_user.get_idcard(TRUE)
			if(!used_id_card || !used_id_card.registered_account)
				say("No bank account detected!")
				return
			if(!purchase_items(used_id_card, express = TRUE))
				return
			var/say_message = "Thank you for your purchase!"
			if(express_cost_multiplier > 1)
				say_message += "Please note: The charge of this purchase and machine cooldown has been multiplied by [express_cost_multiplier]!"
			COOLDOWN_START(src, order_cooldown, cooldown_time * express_cost_multiplier)
			say(say_message)
			var/list/ordered_paths = list()
			for(var/datum/orderable_item/item as anything in grocery_list)//every order
				if(!(item.category_index in order_categories))
					stack_trace("[src] somehow delivered [item] which is not purchasable at this order console.")
					grocery_list.Remove(item)
					continue
				for(var/amt in 1 to grocery_list[item])//every order amount
					ordered_paths += item.item_path
			podspawn(list(
				"target" = get_turf(living_user),
				"style" = STYLE_BLUESPACE,
				"spawn" = ordered_paths,
			))
			grocery_list.Cut()
	return TRUE

/**
 * Checks if an ID card is able to afford the total cost of the current console's grocieries
 * and deducts the cost if they can.
 * Args:
 * card - The ID card we check for balance
 * express - Boolean on whether we need to add the express cost mulitplier
 * returns TRUE if we can afford, FALSE otherwise.
 */
/obj/machinery/computer/order_console/proc/purchase_items(obj/item/card/id/card, express = FALSE)
	var/final_cost = get_total_cost()
	var/failure_message = "Sorry, but you do not have enough money."
	if(express)
		final_cost *= express_cost_multiplier
		failure_message += "Remember, Express upcharges the cost!"
	if(card.registered_account.adjust_money(-final_cost, "[name]: Purchase"))
		return TRUE
	say(failure_message)
	return FALSE

/obj/machinery/computer/order_console/proc/order_groceries(mob/living/purchaser, obj/item/card/id/card, list/groceries, ltsrbt_delivered = FALSE)
	return
